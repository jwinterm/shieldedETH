use anyhow::{bail, ensure, Context, Result};
use ark_bn254::Fr;
use ark_ff::{BigInteger, Field, PrimeField};
use provekit_common::{
    FieldHash, HashConfig, ProofField, PublicInputs, PublicInputsHash, WhirR1CSProof,
    WhirR1CSScheme, WitnessCommitmentMode, R1CS,
};
use provekit_prover::WhirR1CSProver;
use provekit_verifier::WhirR1CSVerifier;
use sha3::{Digest, Keccak256};
use std::{
    collections::BTreeMap,
    fs,
    io::{Cursor, Read},
    path::Path,
    sync::{Arc, Once},
    time::Instant,
};
use whir::{
    algebra::{
        embedding::Identity,
        ntt::{NttEngine, NTT},
    },
    protocols::{
        params::{FoldingFactor, KneeWeight, RateSchedule},
        zook::ProtocolConfig,
    },
    transcript::{Proof, ProverState, VerifierMessage, VerifierState},
};

// Keccak-only BN254 adapter. The upstream protocol and verifier are unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Bn254;
impl ProofField for Bn254 {
    type Embedding = Identity<Fr>;
    const FIELD_ID: u8 = 0;
}
fn field_bytes(x: &Fr) -> Vec<u8> {
    x.into_bigint().to_bytes_le()
}
impl FieldHash for Bn254 {
    fn register() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            NTT.insert(Arc::new(NttEngine::<Fr>::new_from_fftfield()));
        });
    }
    fn hash_public_inputs(config: HashConfig, inputs: &[Fr]) -> Fr {
        assert_eq!(config, HashConfig::Keccak);
        let mut hash = Keccak256::new();
        hash.update(b"PROVEKIT_PUBLIC_INPUTS_V1");
        for x in inputs {
            hash.update(field_bytes(x));
        }
        Fr::from_le_bytes_mod_order(&hash.finalize())
    }
    fn ext_to_bytes_le(x: &Fr) -> Vec<u8> {
        field_bytes(x)
    }
    type Sponge = spongefish::instantiations::Keccak;
    fn transcript_sponge(config: HashConfig) -> Self::Sponge {
        assert_eq!(config, HashConfig::Keccak);
        Self::Sponge::default()
    }
}
fn u32le(r: &mut impl Read) -> Result<u32> {
    let mut b = [0; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}
fn u64le(r: &mut impl Read) -> Result<u64> {
    let mut b = [0; 8];
    r.read_exact(&mut b)?;
    Ok(u64::from_le_bytes(b))
}
fn fe(r: &mut impl Read) -> Result<Fr> {
    let mut b = [0; 32];
    r.read_exact(&mut b)?;
    let x = Fr::from_le_bytes_mod_order(&b);
    ensure!(field_bytes(&x) == b, "noncanonical field element");
    Ok(x)
}
fn sections<'a>(bytes: &'a [u8], magic: &[u8], version: u32) -> Result<BTreeMap<u32, &'a [u8]>> {
    let mut r = Cursor::new(bytes);
    let mut got = [0; 4];
    r.read_exact(&mut got)?;
    ensure!(got == magic, "wrong binary format");
    ensure!(u32le(&mut r)? == version, "unsupported binary version");
    let count = u32le(&mut r)?;
    let mut out = BTreeMap::new();
    for _ in 0..count {
        let kind = u32le(&mut r)?;
        let len: usize = u64le(&mut r)?.try_into()?;
        let start = r.position() as usize;
        let end = start.checked_add(len).context("section length overflow")?;
        ensure!(end <= bytes.len(), "truncated section");
        ensure!(
            out.insert(kind, &bytes[start..end]).is_none(),
            "duplicate section"
        );
        r.set_position(end as u64);
    }
    ensure!(r.position() as usize == bytes.len(), "trailing binary data");
    Ok(out)
}
fn prime(r: &mut impl Read) -> Result<()> {
    ensure!(u32le(r)? == 32, "expected 32-byte BN254 scalar field");
    let mut b = [0; 32];
    r.read_exact(&mut b)?;
    ensure!(
        b.as_slice() == Fr::MODULUS.to_bytes_le(),
        "wrong field modulus"
    );
    Ok(())
}
fn load(r1cs_path: &Path, wtns_path: &Path) -> Result<(R1CS<Fr>, Vec<Fr>, PublicInputs<Fr>)> {
    let bytes = fs::read(r1cs_path)?;
    let s = sections(&bytes, b"r1cs", 1)?;
    let mut h = Cursor::new(*s.get(&1).context("R1CS header missing")?);
    prime(&mut h)?;
    let wires = u32le(&mut h)? as usize;
    let outputs = u32le(&mut h)? as usize;
    let inputs = u32le(&mut h)? as usize;
    let _private_inputs = u32le(&mut h)?;
    let _labels = u64le(&mut h)?;
    let constraints = u32le(&mut h)? as usize;
    ensure!(
        h.position() as usize == h.get_ref().len(),
        "unexpected header length"
    );
    let mut r = Cursor::new(*s.get(&2).context("R1CS constraints missing")?);
    let mut circuit = R1CS::new();
    circuit.add_witnesses(wires);
    circuit.num_public_inputs = inputs + outputs;
    for _ in 0..constraints {
        let mut abc = [Vec::new(), Vec::new(), Vec::new()];
        for terms in &mut abc {
            for _ in 0..u32le(&mut r)? {
                let wire = u32le(&mut r)? as usize;
                ensure!(wire < wires, "wire outside witness");
                terms.push((fe(&mut r)?, wire));
            }
        }
        circuit.add_constraint(&abc[0], &abc[1], &abc[2]);
    }
    ensure!(
        r.position() as usize == r.get_ref().len(),
        "unparsed R1CS constraints"
    );
    let bytes = fs::read(wtns_path)?;
    let s = sections(&bytes, b"wtns", 2)?;
    let mut h = Cursor::new(*s.get(&1).context("witness header missing")?);
    prime(&mut h)?;
    ensure!(
        u32le(&mut h)? as usize == wires,
        "witness dimension mismatch"
    );
    let payload = s.get(&2).context("witness payload missing")?;
    ensure!(
        payload.len() == 32 * wires,
        "witness payload length mismatch"
    );
    let mut r = Cursor::new(*payload);
    let witness = (0..wires).map(|_| fe(&mut r)).collect::<Result<Vec<_>>>()?;
    ensure!(witness[0] == Fr::ONE, "constant wire must equal one");
    let public = PublicInputs::from_vec(witness[1..=circuit.num_public_inputs].to_vec());
    check_witness(&circuit, &witness)?;
    Ok((circuit, witness, public))
}
fn check_witness(circuit: &R1CS<Fr>, witness: &[Fr]) -> Result<()> {
    // Use C*w directly. The prover helper computes A*w * B*w as a candidate C
    // vector, so it cannot serve as an independent satisfaction check.
    let a = circuit.a() * witness;
    let b = circuit.b() * witness;
    let c = circuit.c() * witness;
    for (i, ((a, b), c)) in a.iter().zip(&b).zip(&c).enumerate() {
        ensure!(*a * b == *c, "unsatisfied R1CS row {i}");
    }
    Ok(())
}
fn prove(
    circuit: &R1CS<Fr>,
    witness: Vec<Fr>,
    public: &PublicInputs<Fr>,
) -> Result<(WhirR1CSScheme<Bn254>, WhirR1CSProof)> {
    Bn254::register();
    let mut scheme = WhirR1CSScheme::<Bn254>::new_for_r1cs(
        circuit,
        witness.len(),
        0,
        vec![],
        !public.is_empty(),
        HashConfig::Keccak,
        WitnessCommitmentMode::ZeroKnowledge,
    )?;
    if let Ok(profile) = std::env::var("SETH_WHIR_TUNING") {
        let parts = profile
            .split(',')
            .map(str::parse::<usize>)
            .collect::<std::result::Result<Vec<_>, _>>()?;
        ensure!(
            parts.len() == 2,
            "SETH_WHIR_TUNING must be folding,log_inverse_rate"
        );
        let mut tuning = scheme.whir_witness.tuning().clone();
        tuning.folding_factor = FoldingFactor::ConstantFromSecondRound {
            initial: parts[0],
            rest: parts[0],
        };
        tuning.starting_log_inv_rate = parts[1] as u32;
        // Upstream weights encoding cost by k and proof size by (1-k).
        tuning.rate_schedule = RateSchedule::Adaptive {
            knee_weight: KneeWeight::new(0.0),
        };
        scheme.whir_witness =
            ProtocolConfig::derive(scheme.whir_witness.security().clone(), tuning)
                .map_err(|e| anyhow::anyhow!("parameter derivation failed: {e}"))?;
    }
    let instance = public.hash_bytes::<Bn254>(HashConfig::Keccak);
    let ds = scheme.create_domain_separator().instance(&instance);
    let mut transcript = ProverState::new(&ds, Bn254::transcript_sponge(HashConfig::Keccak));
    let commitment = scheme.commit(
        &mut transcript,
        witness.len(),
        circuit.num_constraints(),
        witness.clone(),
        true,
    )?;
    let proof = scheme.prove_noir(
        transcript,
        circuit.clone(),
        vec![commitment],
        witness,
        public,
    )?;
    Ok((scheme, proof))
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 {
        bail!("usage: seth-transparent-experiment CIRCUIT.r1cs WITNESS.wtns OUTPUT_DIR");
    }
    let out = Path::new(&args[3]);
    fs::create_dir_all(out)?;
    let (circuit, witness, public) = load(Path::new(&args[1]), Path::new(&args[2]))?;
    let start = Instant::now();
    let (scheme, proof) = prove(&circuit, witness.clone(), &public)?;
    let proving_seconds = start.elapsed().as_secs_f64();
    let start = Instant::now();
    scheme.verify(&proof, &public, &circuit)?;
    let verification_seconds = start.elapsed().as_secs_f64();
    let mut rejected = Vec::new();
    for i in 0..public.len() {
        let mut wrong = public.clone();
        wrong.0[i] += Fr::ONE;
        ensure!(
            scheme.verify(&proof, &wrong, &circuit).is_err(),
            "changed public input accepted at {i}"
        );
        rejected.push(format!("changed public input {i}"));
    }
    let mut bad = proof.clone();
    bad.narg_string[0] ^= 1;
    ensure!(
        scheme.verify(&bad, &public, &circuit).is_err(),
        "corrupt proof accepted"
    );
    rejected.push("corrupt proof".into());
    let mut bad = proof.clone();
    bad.narg_string.pop();
    ensure!(
        scheme.verify(&bad, &public, &circuit).is_err(),
        "truncated proof accepted"
    );
    rejected.push("truncated proof".into());
    let mut bad = proof.clone();
    bad.narg_string.push(0);
    ensure!(
        scheme.verify(&bad, &public, &circuit).is_err(),
        "trailing proof bytes accepted"
    );
    rejected.push("trailing proof bytes".into());
    let mut bad = proof.clone();
    let last = bad.hints.len() - 1;
    bad.hints[last] ^= 1;
    ensure!(
        scheme.verify(&bad, &public, &circuit).is_err(),
        "corrupt authentication hints accepted"
    );
    rejected.push("corrupt authentication hints".into());
    let mut bad = proof.clone();
    bad.hints.pop();
    ensure!(
        scheme.verify(&bad, &public, &circuit).is_err(),
        "truncated authentication hints accepted"
    );
    rejected.push("truncated authentication hints".into());
    let mut wrong = circuit.clone();
    wrong.add_constraint(&[(Fr::ONE, 0)], &[(Fr::ONE, 0)], &[]);
    ensure!(
        scheme.verify(&proof, &public, &wrong).is_err(),
        "wrong circuit accepted"
    );
    rejected.push("wrong circuit".into());
    let mut wrong_witness = witness;
    wrong_witness[circuit.num_public_inputs + 1] += Fr::ONE;
    ensure!(
        check_witness(&circuit, &wrong_witness).is_err(),
        "invalid witness escaped independent R1CS check"
    );
    let (bad_scheme, bad_proof) = prove(&circuit, wrong_witness, &public)?;
    ensure!(
        bad_scheme.verify(&bad_proof, &public, &circuit).is_err(),
        "proof of invalid witness accepted"
    );
    rejected.push("proof of invalid private witness".into());
    let privacy_counterexample = privacy_counterexample()?;
    fs::write(out.join("proof.narg.bin"), &proof.narg_string)?;
    fs::write(out.join("proof.hints.bin"), &proof.hints)?;
    fs::write(out.join("scheme.json"), serde_json::to_vec_pretty(&scheme)?)?;
    let report = serde_json::json!({
        "constraints": circuit.num_constraints(), "wires": circuit.num_witnesses(), "publicInputs": public.len(),
        "publicValues": public.0.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "proofBytes": proof.narg_string.len(), "hintBytes": proof.hints.len(),
        "provingSeconds": proving_seconds, "verificationSeconds": verification_seconds,
        "verified": true, "negativeChecks": rejected,
        "witnessCommitmentMode": "zero-knowledge", "sumcheckBlinding": true,
        "fullZeroKnowledgeEstablished": false,
        "privacyLimitation": "Upstream sends witness-dependent alpha evaluations in the clear; hiding witness commitments do not establish full proof zero knowledge.",
        "securityProfile": "upstream 128-bit Johnson-bound commitment target, 10-bit per-slot proof of work",
        "hash": "Keccak", "matrixClosing": "direct sparse, native verifier", "productionEligible": false
        ,"privacyCounterexample": privacy_counterexample,
        "tuning": std::env::var("SETH_WHIR_TUNING").unwrap_or_else(|_| "upstream default".into())
    });
    fs::write(out.join("native.json"), serde_json::to_vec_pretty(&report)?)?;
    println!("Verified {} constraints; proof {} bytes plus {} hint bytes; {:.3}s proving, {:.3}s verification. Privacy and EVM gates remain closed.",
        circuit.num_constraints(), proof.narg_string.len(), proof.hints.len(), proving_seconds, verification_seconds);
    Ok(())
}

// Reproduce the upstream ZK caveat without using a payment witness. In this
// satisfiable relation, x is entirely private and unconstrained: x * 1 = x
// in both rows. The public transcript nevertheless reveals x as A(alpha).
fn privacy_counterexample() -> Result<bool> {
    let mut circuit = R1CS::new();
    circuit.add_witnesses(3);
    circuit.num_public_inputs = 1;
    for _ in 0..2 {
        circuit.add_constraint(&[(Fr::ONE, 2)], &[(Fr::ONE, 0)], &[(Fr::ONE, 2)]);
    }
    let hidden = Fr::from(1234567u64);
    let public = PublicInputs::from_vec(vec![Fr::from(9u64)]);
    let (scheme, proof) = prove(&circuit, vec![Fr::ONE, public.0[0], hidden], &public)?;
    scheme.verify(&proof, &public, &circuit)?;
    let instance = public.hash_bytes::<Bn254>(HashConfig::Keccak);
    let ds = scheme.create_domain_separator().instance(&instance);
    let raw = Proof {
        narg_string: proof.narg_string,
        hints: proof.hints,
        #[cfg(debug_assertions)]
        pattern: proof.pattern,
    };
    let mut reader = VerifierState::new(&ds, &raw, Bn254::transcript_sponge(HashConfig::Keccak));
    let _ = scheme
        .whir_witness
        .receive_commitment(&mut reader)
        .map_err(|_| anyhow::anyhow!("toy commitment parse"))?;
    let _ = scheme
        .whir_blinding
        .receive_commitment(&mut reader)
        .map_err(|_| anyhow::anyhow!("toy mask parse"))?;
    let _: Vec<Fr> = reader.verifier_message_vec(scheme.m_0);
    let _: Fr = reader
        .prover_message()
        .map_err(|_| anyhow::anyhow!("toy sum parse"))?;
    let _: Fr = reader.verifier_message();
    for _ in 0..scheme.m_0 {
        for _ in 0..4 {
            let _: Fr = reader
                .prover_message()
                .map_err(|_| anyhow::anyhow!("toy round parse"))?;
        }
        let _: Fr = reader.verifier_message();
    }
    let _: Fr = reader
        .prover_message()
        .map_err(|_| anyhow::anyhow!("toy blinding evaluation"))?;
    let _: Fr = reader
        .prover_message()
        .map_err(|_| anyhow::anyhow!("toy public hash"))?;
    let _: Fr = reader.verifier_message();
    let revealed: Fr = reader
        .prover_message()
        .map_err(|_| anyhow::anyhow!("toy private evaluation"))?;
    ensure!(
        revealed == hidden,
        "privacy counterexample did not reproduce"
    );
    Ok(true)
}
