// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Development fixtures only. Never used as a production asset or verifier.
contract TestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public pulls;
    uint8 public mode;
    function setMode(uint8 m) external { mode = m; }
    function mint(address to, uint256 value) external { balanceOf[to] += value; }
    function approve(address spender, uint256 value) external returns (bool) { allowance[msg.sender][spender] = value; return true; }
    function transfer(address to, uint256 value) external returns (bool) { return _move(msg.sender, to, value); }
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        pulls++;
        allowance[from][msg.sender] -= value;
        return _move(from, to, value);
    }
    function _move(address from, address to, uint256 value) internal returns (bool) {
        require(mode != 1, "token paused");
        if (mode == 2) return false;
        if (mode == 3) return true; // dishonest no-op success
        balanceOf[from] -= value + (mode == 5 ? 1 : 0);
        balanceOf[to] += value - (mode == 4 ? 1 : 0);
        if (mode == 6) assembly { return(0, 0) }
        if (mode == 7) assembly { mstore(0, 1) return(0, 1) }
        if (mode == 8) assembly { mstore(0, 1) return(0, 65536) }
        return true;
    }
}

contract RejectETH { receive() external payable { revert("recipient refused"); } }

contract StorageProbe {
    uint256 public value;
    function increment() external { value++; }
}

contract ReentryReceiver {
    bool public blocked;
    receive() external payable {
        (bool ok,) = msg.sender.call(abi.encodeWithSignature("claimInsertionFees(address,uint256)", address(this), 1));
        blocked = !ok;
    }
}

contract KernelPoolFixture {
    uint16 public VERSION = 8;
    bytes32 public constant poolId = keccak256("local kernel test pool");
    bool public accepting;
    uint40 public nextEntry;
    function assetToken(uint256) external pure returns (address) { return address(0); }
    function setVersion(uint16 v) external { VERSION = v; }
    function setAccepting(bool v) external { accepting = v; }
    function deposit(uint8 asset, uint256, uint128 amount, bytes calldata ct) external payable returns (uint40) {
        require(accepting && asset == 0 && msg.value >= amount && ct.length == 109, "deposit refused");
        return nextEntry++;
    }
}

contract KernelSameBlockProbe {
    bool public claimSucceeded;
    bool public deliveryRefused;
    function probe(address kernel, bytes calldata claim, bytes calldata delivery) external {
        (bool ok,) = kernel.call(claim);
        require(ok, "claim failed");
        claimSucceeded = true;
        (ok,) = kernel.call(delivery);
        deliveryRefused = !ok;
    }
}
