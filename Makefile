.PHONY: check contracts circuits witnesses integration docs paper
check:
	npm run check
contracts:
	npm run build:contracts
circuits:
	npm run build:circuits
witnesses:
	npm run test:circuits
integration:
	npm run test:integration
docs:
	npm run docs
paper:
	sh scripts/render-paper.sh
