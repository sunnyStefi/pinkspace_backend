include .env

.PHONY: all test clean deploy fund help install snapshot format anvil #do no generate any files

#target that has to be executed regardless of its timestamp (PHONY)

clean  :; forge clean

remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; forge install Cyfrin/foundry-devops@0.1.0 --no-commit && forge install foundry-rs/forge-std@v1.5.3 --no-commit && forge install openzeppelin/openzeppelin-contracts@v4.8.3 --no-commit

update:; forge update

build:; forge build

SEPOLIA_ARGS := --rpc-url $(SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

#@ prevents to print the command 
# mint:
# 	@forge script script/Interaction.s.sol:MintBasicNFT $(SEPOLIA_ARGS)
gas:
	forge test --gas-report

snap:
	forge snapshot --asc

deploy: 
	sudo rm -rf broadcast && sudo rm -rf cache
	@forge script script/Deployment.s.sol:Deployment $(SEPOLIA_ARGS)

build:
	forge build --skip script --skip test --skip progress

# sepolia scripts to perform standard user operations with Course contract

removeAll:
	forge script script/Interaction.s.sol:RemoveAll $(SEPOLIA_ARGS) 

createCourses:
	forge script script/Interaction.s.sol:CreateCourses $(SEPOLIA_ARGS) 

setUpEvaluator:
	forge script script/Interaction.s.sol:SetUpEvaluator $(SEPOLIA_ARGS)

buyPlaces:
	forge script script/Interaction.s.sol:BuyCourses $(SEPOLIA_ARGS)

transferNFT:
	forge script script/Interaction.s.sol:TransferNFT $(SEPOLIA_ARGS)

evaluate:
	forge script script/Interaction.s.sol:Evaluate $(SEPOLIA_ARGS)

makeCourses:
	forge script script/Interaction.s.sol:MakeCourses $(SEPOLIA_ARGS)

all: createCourses setUpEvaluator buyPlaces  transferNFT evaluate  makeCourses

push:
	git add .
	git commit -m "readme"
	git push origin main