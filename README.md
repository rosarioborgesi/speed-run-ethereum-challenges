# Speed Run Ethereum - Smart Contract Challenges

This repository contains my solutions to the [Speed Run Ethereum](https://speedrunethereum.com) challenges, featuring complete smart contract implementations deployed on Sepolia testnet.

## 🧠 Skills Demonstrated

Through these challenges I implemented core building blocks of the Ethereum ecosystem including:

- Solidity smart contract development
- DeFi primitives (AMMs, lending, stablecoins)
- Oracle mechanisms and dispute systems
- Prediction markets
- Smart contract security concepts (randomness attacks)
- Zero-knowledge proofs and Merkle tree membership verification
- ERC standards (ERC20, ERC721)

All contracts are deployed on Sepolia and integrated with live frontends.

## 👤 Builder Profile

View my complete portfolio: [speedrunethereum.com/builders/0xce626A7dF0e36281e410Faa1808685BB17779741](https://speedrunethereum.com/builders/0xce626A7dF0e36281e410Faa1808685BB17779741)

## 📁 Repository Structure

Each folder in the `src/` directory contains the implementation for a specific challenge.

## 🎯 Completed Challenges

### Challenge 0: Tokenization
**Objective:** Build and deploy a basic ERC-721 NFT contract.

**Description:**  
In this challenge I implemented a simple ERC-721 token contract to understand NFT standards and tokenized ownership on Ethereum. The contract supports minting unique tokens and managing ownership through the ERC-721 interface. This exercise demonstrates how digital assets can represent ownership of unique items on-chain.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/tokenization)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0x3ef2b1569BCC227b00760af6B328e1272970CC48)
- 🚀 [Live Demo](https://challenge-tokenization-oh374vdce-rosariobs-projects.vercel.app/)

---

### Challenge 1: Crowdfunding
**Objective:** Build a decentralized crowdfunding platform using smart contracts.

**Description:**  
In this challenge I built a crowdfunding contract where users can contribute ETH to fund a project. Funds are held in the contract and released only if the funding goal is reached. Contributors can withdraw their funds if the goal is not met, ensuring trustless and transparent fundraising.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/crowdfunding)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0xb505b78Ab38813E83dc4A3299e9d2325BaA17c9F)
- 🚀 [Live Demo](https://crowdfunding-rnsmdemv0-rosariobs-projects.vercel.app/)

---

### Challenge 2: Token Vendor
**Objective:** Build a token vendor that allows users to buy and sell ERC-20 tokens.

**Description:**  
In this challenge I created a token vendor contract where users can purchase ERC-20 tokens with ETH and sell them back to the contract. The system demonstrates token minting, price calculation, and secure token transfers while handling ETH payments through smart contracts.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/token-vendor)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0xa487b605453A97c97D0940C6fA7f9A4cF43dbC9a)
- 🚀 [Live Demo](https://token-vendor-g98zttynm-rosariobs-projects.vercel.app/)

---

### Challenge 3: Dice Game
**Objective:** Demonstrate how insecure randomness can be exploited in smart contracts.

**Description:**  
In this challenge I implemented a dice game contract and then built an attacker contract that predicts the outcome by exploiting block variables used for randomness. This exercise highlights common smart contract security pitfalls and shows why secure randomness solutions like VRF are necessary.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/dice-game)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0x4D778BbE2678295e15a10f79Cc5d82aD6ddf1A9E)
- 🚀 [Live Demo](https://dice-game-mi4zhtstv-rosariobs-projects.vercel.app/)

---

### Challenge 4: DEX
**Objective:** Build a simple decentralized exchange using an Automated Market Maker (AMM).

**Description:**  
In this challenge I implemented a Uniswap-style AMM that allows users to swap ETH and ERC-20 tokens. Liquidity providers can deposit assets into a pool and earn fees from swaps. The contract uses the constant product formula to maintain price balance between assets.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/dex)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0xd68f1215e9f696DC47afDAc645Ca073447e9f85C)
- 🚀 [Live Demo](https://dex-d5b7q57ci-rosariobs-projects.vercel.app/)

---

### Challenge 5: Oracles
**Objective:** Build a staking-based optimistic oracle system.

**Description:**  
In this challenge I implemented a whitelist, staking mechanism, and an optimistic oracle. Participants can propose off-chain data, while stakers can challenge incorrect values. If the data is not disputed, it is accepted as valid. This design demonstrates how decentralized oracle systems can securely bring external data on-chain.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/oracles)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0x8b2791BA100c2ad81587BE8337353f07dA20e2b0)
- 🚀 [Live Demo](https://oracles-hxrmyx70q-rosariobs-projects.vercel.app)

---

### Challenge 6: Over Collateralized Lending
**Objective:** Build a decentralized lending and borrowing protocol.

**Description:**  
In this challenge I developed a lending protocol where users deposit ETH as collateral and borrow a token against it. The system enforces collateralization ratios to maintain solvency and allows liquidations if positions become undercollateralized. This exercise demonstrates the core mechanics behind DeFi lending platforms like Aave.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/over-collateralized-lending)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0x5F583dF41dE1408819c82481a5442d9a3bb3dA4f)
- 🚀 [Live Demo](https://over-collateralized-lending-pp1xiqflx-rosariobs-projects.vercel.app/)

---

### Challenge 7: Stablecoins
**Objective:** Build an overcollateralized stablecoin system.

**Description:**  
In this challenge I implemented a stablecoin protocol where users lock collateral to mint a stable token pegged to USD. The system manages collateral ratios, borrowing mechanics, and liquidation logic to maintain solvency. This architecture mirrors core components of protocols like MakerDAO.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/stablecoins)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0x572ab479E93BC707FA04880154cec91499435edf)
- 🚀 [Live Demo](https://stablecoins-ao2wam0bz-rosariobs-projects.vercel.app)

---

### Challenge 8: Prediction Markets
**Objective:** Build a decentralized prediction market.

**Description:**  
In this challenge I implemented a prediction market where users can bet on the outcome of an event by purchasing YES or NO tokens. Once the event is resolved by an oracle, winning token holders can redeem their share of the pooled funds. This demonstrates core mechanics behind prediction markets like Polymarket.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/prediction-markets)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0xCCcb8298Ae8dC4D38329Ea44790b0CAc69e6D67E)
- 🚀 [Live Demo](https://prediction-market-hk4dbteer-rosariobs-projects.vercel.app/)

---

### Challenge 9: ZK Voting
**Objective:** Build a privacy-preserving voting system using zero-knowledge proofs.

**Description:**  
In this challenge I implemented an anonymous on-chain voting protocol where only allowlisted voters can participate. Each voter registers a cryptographic commitment in an incremental Merkle tree and later proves membership using a zero-knowledge proof without revealing their identity. Nullifier hashes prevent double voting while preserving voter privacy. The smart contract verifies the proof on-chain and securely tallies YES/NO votes.

- 🔗 [Challenge Details](https://speedrunethereum.com/challenge/zk-voting)
- 📝 [Contract on Sepolia](https://sepolia.etherscan.io/address/0xE9b7F72C9B7d96116CA06b7c31bd1BB002884a9E)
- 🚀 [Live Demo](https://zk-voting-9kopkvmpe-rosariobs-projects.vercel.app)

## 📄 License

This project is open source and available for educational purposes.

## 🌐 Connect with Me
<p align="left">
  <a href="https://x.com/rosarioborgesi">
    <img src="https://img.shields.io/badge/twitter-000000?style=for-the-badge&logo=x&logoColor=white"/>
  </a>
  <a href="https://www.linkedin.com/in/rosarioborgesi/">
    <img src="https://img.shields.io/badge/LinkedIn-0A66C2?style=for-the-badge&logo=linkedin&logoColor=white"/>
  </a>
  <a href="mailto:borgesiros@gmail.com">
    <img src="https://img.shields.io/badge/Email-D14836?style=for-the-badge&logo=gmail&logoColor=white"/>
  </a>
  <a href="https://www.youtube.com/@rosarioborgesi">
    <img src="https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white"/>
  </a>
  <a href="https://farcaster.xyz/rosarioborgesi">
    <img src="https://img.shields.io/badge/Farcaster-855DCD?style=for-the-badge"/>
  </a>
  <a href="https://medium.com/@rosarioborgesi/">
    <img src="https://img.shields.io/badge/Medium-000000?style=for-the-badge&logo=medium&logoColor=white"/>
  </a>
</p>


