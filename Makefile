# Load environment variables
include .env
export

# Default target
.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make anvil                    - Start Anvil with tracing enabled"
	@echo "  make deploy-anvil             - Deploy Bazaar to local Anvil"
	@echo "  make deploy-pair-anvil        - Deploy a pair (FEED_ID=2 CONTINUOUS=true|false DESC=... [PRICE=2000])"
	@echo "  make deploy-libs-arb-sepolia  - Step 1/2: deploy libraries to Arbitrum Sepolia"
	@echo "  make deploy-arb-sepolia       - Step 2/2: deploy Bazaar to Arbitrum Sepolia"
	@echo "  make deploy-libs-arb-mainnet  - Step 1/2: deploy libraries to Arbitrum Mainnet"
	@echo "  make deploy-arb-mainnet       - Step 2/2: deploy Bazaar to Arbitrum Mainnet"
	@echo "  make set-price-anvil          - Store a test price on a pair (PAIR=0x... PRICE=2000)"
	@echo "  make deposit-anvil            - Deposit collateral into a pair (PAIR=0x... AMOUNT=1000)"
	@echo "  make create-order-anvil       - Create limit order (PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true)"
	@echo "  make warp-anvil SECONDS=N     - Warp Anvil forward N seconds"
	@echo "  make build                    - Build the project"
	@echo "  make abis                     - Build, export the ABIs to abi/, check src/interfaces/ against them"
	@echo "  make test                     - Run tests"
	@echo "  make balance-usdc             - Check USDC balance (ADDR=0x... optional)"
	@echo "  make clean                    - Clean build artifacts"
	@echo "  make install                  - Install dependencies"

# Build
.PHONY: build
build:
	forge build

# ABIs for indexers and frontends, committed under abi/. The exported BazaarPair.json adds the
# events and errors of the libraries the pair links, which its compiled ABI omits (see
# script/export-abis.sh). The check then fails unless each MIT interface in src/interfaces/
# declares exactly what its contract exports. CI runs both, and fails if abi/ is stale.
.PHONY: abis
abis: build
	bash script/export-abis.sh
	bash script/check-interfaces.sh

# Test
.PHONY: test
test:
	forge test

.PHONY: test-factory
test-factory:
	forge test --match-contract BazaarFactoryTest -vv

# Clean
.PHONY: clean
clean:
	forge clean

# Install dependencies
.PHONY: install
install:
	forge install

# Start Anvil
.PHONY: anvil
anvil:
	anvil --steps-tracing --code-size-limit 100000

# ---------- Anvil Local Deployment ----------

.PHONY: deploy-anvil
deploy-anvil:
	@echo "=== Deploying Bazaar to Anvil ===" && \
	forge script script/DeployBazaar.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast \
		--private-key $(ANVIL_PRIVATE_KEY) \
		--code-size-limit 100000 2>&1 | tee /tmp/bazaar-deploy.log && \
	FACTORY_ADDR=$$(grep "BazaarFactory:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	ORACLE_ADDR=$$(grep "BazaarOracle:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	PAIR_IMPL_ADDR=$$(grep "BazaarPair implementation:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	LENS_ADDR=$$(grep "BazaarPairLens:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	TERMINATOR_ADDR=$$(grep "BazaarPairTerminator:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	USDC_ADDR=$$(grep "USDC:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	OOV3_ADDR=$$(grep "OptimisticOracleV3:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	echo "" && \
	echo "=== Etching MockArbSys at the ArbSys precompile address (0x64) ===" && \
	([ -f out/MockArbSys.sol/MockArbSys.json ] || forge build > /dev/null) && \
	ARBSYS_CODE=$$(jq -r '.deployedBytecode.object' out/MockArbSys.sol/MockArbSys.json) && \
	cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 $$ARBSYS_CODE \
		--rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	echo "" && \
	echo "=== Minting 10,000 MockUSDC to $(ANVIL_WALLET) ===" && \
	cast send $$USDC_ADDR \
		"mint(address,uint256)" \
		$(ANVIL_WALLET) 10000000000 \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) && \
	echo "" && \
	echo "=== Deployment Complete ===" && \
	echo "  MockUSDC:              $$USDC_ADDR" && \
	echo "  MockOptimisticOracleV3:$$OOV3_ADDR" && \
	echo "  BazaarFactory:         $$FACTORY_ADDR" && \
	echo "  BazaarOracle:          $$ORACLE_ADDR" && \
	echo "  BazaarPair (impl):     $$PAIR_IMPL_ADDR" && \
	echo "  BazaarPairLens:        $$LENS_ADDR" && \
	echo "  BazaarPairTerminator:  $$TERMINATOR_ADDR" && \
	printf "OOV3=%s\nUSDC=%s\nFACTORY=%s\nORACLE=%s\nPAIR_IMPL=%s\nLENS=%s\nTERMINATOR=%s\n" \
		$$OOV3_ADDR $$USDC_ADDR $$FACTORY_ADDR $$ORACLE_ADDR $$PAIR_IMPL_ADDR $$LENS_ADDR $$TERMINATOR_ADDR \
		> .anvil-addresses

# ---------- Anvil Utilities ----------

.PHONY: warp-anvil
warp-anvil:
	@if [ -z "$(SECONDS)" ]; then echo "Usage: make warp-anvil SECONDS=43200"; exit 1; fi
	@echo "Warping Anvil forward $(SECONDS) seconds..."
	@cast rpc evm_increaseTime $(SECONDS) --rpc-url $(ANVIL_RPC_URL) > /dev/null
	@cast rpc evm_mine --rpc-url $(ANVIL_RPC_URL) > /dev/null
	@echo "Done. Block mined at new timestamp."

# These read addresses saved by deploy-anvil in .anvil-addresses

.PHONY: balance-usdc
balance-usdc:
	@. ./.anvil-addresses && \
	cast call $$USDC "balanceOf(address)(uint256)" $(or $(ADDR),$(ANVIL_WALLET)) --rpc-url $(ANVIL_RPC_URL)

# Store a test price on a pair on Anvil
# Usage: make set-price-anvil PAIR=0x... PRICE=2000 (USD price as integer)
# Pyth Pro keeps no price on-chain, so a price is set on a pair: this signs an update for the pair's
# feed with the test key the local MockPythLazer trusts (script/dev-update.sh) and has the pair store
# it through refreshPrice. A composite pair needs both legs in the update and is not covered. Anvil
# mines a block only when a transaction arrives, so the latest block's timestamp can be long past;
# the update is stamped one second after it and the block carrying it is pinned to that second, so
# the price is fresh when it lands.
.PHONY: set-price-anvil
set-price-anvil:
	@if [ -z "$(PAIR)" ] || [ -z "$(PRICE)" ]; then echo "Usage: make set-price-anvil PAIR=0x... PRICE=2000"; exit 1; fi
	@BASE_FEED=$$(cast call $(PAIR) "baseFeedId()(bytes32)" --rpc-url $(ANVIL_RPC_URL)) && \
	TIMESTAMP=$$(( $$(cast block latest --rpc-url $(ANVIL_RPC_URL) --json | jq -r '.timestamp' | xargs printf "%d") + 1 )) && \
	echo "=== Storing price: $(PRICE) USD ===" && \
	UPDATE=$$(bash script/dev-update.sh $$BASE_FEED $(PRICE)00000000 $$TIMESTAMP) && \
	cast rpc evm_setNextBlockTimestamp $$TIMESTAMP --rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	cast send $(PAIR) \
		"refreshPrice(bytes[])" "[$$UPDATE]" \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) > /dev/null && \
	echo "Done. Price set to $(PRICE) USD" && \
	echo "" && \
	echo "=== Price update data for Remix (pass as priceUpdate within 3 s of that timestamp) ===" && \
	echo "[\"$$UPDATE\"]"

# Deposit collateral into a pair on Anvil
# Usage: make deposit-anvil PAIR=0x... AMOUNT=1000 (USD, whole dollars; at least 5)
.PHONY: deposit-anvil
deposit-anvil:
	@if [ -z "$(PAIR)" ] || [ -z "$(AMOUNT)" ]; then echo "Usage: make deposit-anvil PAIR=0x... AMOUNT=1000"; exit 1; fi
	@. ./.anvil-addresses && \
	echo "=== Approving $(AMOUNT) USDC for the pair ===" && \
	cast send $$USDC "approve(address,uint256)" $(PAIR) $(AMOUNT)000000 \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) > /dev/null && \
	echo "=== Depositing $(AMOUNT) USDC as collateral ===" && \
	cast send $(PAIR) \
		"depositCollateral(uint256,uint256,uint256,uint256,bytes,bytes)" \
		$$(cast to-wei $(AMOUNT)) 0 0 0 0x 0x \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) > /dev/null && \
	echo "Done. Deposited $(AMOUNT) USDC into $(PAIR)"

# Create a limit order on Anvil (generates fresh price data in the same command)
# Usage: make create-order-anvil PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true
# LIMIT_PRICE is in USD (integer), SIZE is in units of the asset (e.g. 0.01 ETH). The order is
# margined against collateral already in the pair (make deposit-anvil). It is a GTC limit that
# expires 100,000 blocks from now; the pair accepts lifetimes from 240 blocks to ~1 year. The price
# update carries the limit price as the oracle price, signed with the local test key
# (script/dev-update.sh), and is stamped with the timestamp the order's block is pinned to, since
# the pair refuses an update more than 3 s old.
.PHONY: create-order-anvil
create-order-anvil:
	@if [ -z "$(PAIR)" ] || [ -z "$(LIMIT_PRICE)" ] || [ -z "$(SIZE)" ]; then \
		echo "Usage: make create-order-anvil PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true"; exit 1; fi
	@BASE_FEED=$$(cast call $(PAIR) "baseFeedId()(bytes32)" --rpc-url $(ANVIL_RPC_URL)) && \
	TIMESTAMP=$$(( $$(cast block latest --rpc-url $(ANVIL_RPC_URL) --json | jq -r '.timestamp' | xargs printf "%d") + 1 )) && \
	EXPIRATION=$$(( $$(cast block-number --rpc-url $(ANVIL_RPC_URL)) + 100000 )) && \
	BASE_UPDATE=$$(bash script/dev-update.sh $$BASE_FEED $(LIMIT_PRICE)00000000 $$TIMESTAMP) && \
	SIZE_WEI=$$(cast to-wei $(SIZE)) && \
	LIMIT_WEI=$$(cast to-wei $(LIMIT_PRICE)) && \
	echo "=== Creating limit order ===" && \
	echo "  Pair:        $(PAIR)" && \
	echo "  Size:        $(SIZE) ($$SIZE_WEI)" && \
	echo "  Limit price: $(LIMIT_PRICE) USD" && \
	echo "  Long:        $(or $(IS_LONG),true)" && \
	cast rpc evm_setNextBlockTimestamp $$TIMESTAMP --rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	cast send $(PAIR) \
		"createOrder((uint8,bool,bool,uint8,uint256,uint256,uint256,uint256,uint64,address),(uint64,uint64,uint64,uint64,uint32),bytes[],uint256,uint256,uint256,bytes,bytes)" \
		"(1,$(or $(IS_LONG),true),false,0,$$SIZE_WEI,0,$$LIMIT_WEI,0,$$EXPIRATION,0x0000000000000000000000000000000000000000)" \
		"(0,0,0,0,0)" \
		"[$$BASE_UPDATE]" 0 0 0 0x 0x \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) \
		--gas-limit 5000000 && \
	echo "=== Order created ==="

# Deploy a pair on Anvil
# Usage: make deploy-pair-anvil FEED_ID=2 CONTINUOUS=true DESC="ETH/USD" [PRICE=2000]
# FEED_ID is the Pyth Pro feed ID, a number (2 is ETH/USD); the factory takes it as a bytes32. With
# PRICE the new pair is given that price once it is deployed (set-price-anvil).
.PHONY: deploy-pair-anvil
deploy-pair-anvil:
	@if [ -z "$(FEED_ID)" ]; then echo "Usage: make deploy-pair-anvil FEED_ID=2 CONTINUOUS=true|false DESC=\"ETH/USD\" [PRICE=2000]"; exit 1; fi
	@set -e && . ./.anvil-addresses && \
	FEED=$$(cast to-uint256 $(FEED_ID)) && \
	AMOUNT=5000000000000000000000 && \
	AMOUNT_USDC=5000000000 && \
	echo "=== Step 1: Approving 5000 USDC for Factory ===" && \
	cast send $$USDC "approve(address,uint256)" $$FACTORY $$AMOUNT_USDC \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) > /dev/null && \
	echo "=== Step 2: Proposing Pair Deployment ===" && \
	PROPOSE_JSON=$$(cast send $$FACTORY \
		"proposePairDeployment(bytes32,bool,uint256,string)" \
		$$FEED $(or $(CONTINUOUS),true) $$AMOUNT "$(or $(DESC),Pair)" \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) --json) && \
	TX_HASH=$$(echo "$$PROPOSE_JSON" | jq -r '.transactionHash') && \
	ASSERTION_ID=$$(cast receipt $$TX_HASH --rpc-url $(ANVIL_RPC_URL) --json | \
		jq -r '.logs[] | select(.topics[0] == "0xb3076a86f17e6bb64607292bdf4d72989c0cbe43651a097d912dd1a4b9c82dd6") | .topics[2]') && \
	echo "  Assertion ID: $$ASSERTION_ID" && \
	echo "=== Step 3: Warping 48 hours (DEPLOYMENT_LIVENESS) ===" && \
	cast rpc evm_increaseTime 172801 --rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	cast rpc evm_mine --rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	echo "=== Step 4: Settling Deployment ===" && \
	cast send $$FACTORY \
		"settleDeploymentProposal(bytes32)" $$ASSERTION_ID \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) \
		--gas-limit 5000000 2>/dev/null; \
	PAIR_ADDR=$$(cast call $$FACTORY "getPairAddress(bytes32)(address)" $$FEED --rpc-url $(ANVIL_RPC_URL)) && \
	if [ "$$PAIR_ADDR" = "0x0000000000000000000000000000000000000000" ]; then \
		echo "ERROR: Pair deployment failed!" && exit 1; \
	fi && \
	echo "" && \
	echo "=== Pair Deployed ===" && \
	echo "  Feed ID:      $(FEED_ID)" && \
	echo "  Continuous:   $(or $(CONTINUOUS),true)" && \
	echo "  Description:  $(or $(DESC),Pair)" && \
	echo "  Assertion ID: $$ASSERTION_ID" && \
	echo "  Pair Address: $$PAIR_ADDR" && \
	if [ -n "$(PRICE)" ]; then \
		$(MAKE) --no-print-directory set-price-anvil PAIR=$$PAIR_ADDR PRICE=$(PRICE); \
	fi

# ---------- Two-step deployment ----------
# The core contracts link twelve external libraries by address (eleven in BazaarPair, ClaimTextLib in
# the factory and the terminator), so every network needs its own library deployment before the
# Bazaar deploy can be linked. DeployLibraries writes that chain's
# `--libraries` flags to deployments/<chainid>/libraries.args; the deploy targets below splat the
# file for their own chain, so one network's addresses can never be linked into another's build.
#
# That guarantee holds only as long as the RPC alias actually serves the chain the target names --
# the args path is chosen here, not read off the network. Every target therefore passes
# EXPECTED_CHAIN_ID, and both scripts abort before broadcasting if block.chainid disagrees. The
# chain id is written once per network below and feeds both the args path and the assertion, so
# the two cannot drift apart.
#
# The `test -f` below is only the fast failure. Step 2 reads the record back before it broadcasts
# and requires each recorded address to hold the code the build links against
# (DeployBazaar._assertLinkedLibraries), so a record left over from an earlier library build, or
# one missing a library, aborts the run instead of linking the pair to stale code.

ARB_SEPOLIA_CHAIN_ID := 421614
ARB_MAINNET_CHAIN_ID := 42161

ARB_SEPOLIA_LIB_ARGS := deployments/$(ARB_SEPOLIA_CHAIN_ID)/libraries.args
ARB_MAINNET_LIB_ARGS := deployments/$(ARB_MAINNET_CHAIN_ID)/libraries.args

# ---------- Arbitrum Sepolia ----------

.PHONY: deploy-libs-arb-sepolia
deploy-libs-arb-sepolia:
	@echo "Step 1/2: deploying external libraries to Arbitrum Sepolia..."
	EXPECTED_CHAIN_ID=$(ARB_SEPOLIA_CHAIN_ID) \
	forge script script/DeployLibraries.s.sol \
		--rpc-url arbitrum_sepolia \
		--account $(ACCOUNT) \
		--sender $(SENDER) \
		--broadcast \
		--verify

.PHONY: deploy-arb-sepolia
deploy-arb-sepolia:
	@test -f $(ARB_SEPOLIA_LIB_ARGS) || { \
		echo "ERROR: $(ARB_SEPOLIA_LIB_ARGS) not found."; \
		echo "Run 'make deploy-libs-arb-sepolia' first (step 1 of 2)."; \
		exit 1; }
	@echo "Step 2/2: deploying Bazaar to Arbitrum Sepolia..."
	EXPECTED_CHAIN_ID=$(ARB_SEPOLIA_CHAIN_ID) \
	forge script script/DeployBazaar.s.sol \
		--rpc-url arbitrum_sepolia \
		--account $(ACCOUNT) \
		--sender $(SENDER) \
		--broadcast \
		--verify \
		$$(cat $(ARB_SEPOLIA_LIB_ARGS))

# ---------- Arbitrum Mainnet ----------

.PHONY: deploy-libs-arb-mainnet
deploy-libs-arb-mainnet:
	@echo "Step 1/2: deploying external libraries to Arbitrum MAINNET..."
	@read -p "Deploy libraries to mainnet? (y/N): " confirm && [ "$$confirm" = "y" ]
	EXPECTED_CHAIN_ID=$(ARB_MAINNET_CHAIN_ID) \
	forge script script/DeployLibraries.s.sol \
		--rpc-url arbitrum_mainnet \
		--account $(ACCOUNT) \
		--sender $(SENDER) \
		--broadcast \
		--verify

.PHONY: deploy-arb-mainnet
deploy-arb-mainnet:
	@test -f $(ARB_MAINNET_LIB_ARGS) || { \
		echo "ERROR: $(ARB_MAINNET_LIB_ARGS) not found."; \
		echo "Run 'make deploy-libs-arb-mainnet' first (step 1 of 2)."; \
		exit 1; }
	@echo "Step 2/2: deploying Bazaar to Arbitrum MAINNET..."
	@read -p "Are you sure you want to deploy to mainnet? (y/N): " confirm && [ "$$confirm" = "y" ]
	EXPECTED_CHAIN_ID=$(ARB_MAINNET_CHAIN_ID) \
	forge script script/DeployBazaar.s.sol \
		--rpc-url arbitrum_mainnet \
		--account $(ACCOUNT) \
		--sender $(SENDER) \
		--broadcast \
		--verify \
		$$(cat $(ARB_MAINNET_LIB_ARGS))
