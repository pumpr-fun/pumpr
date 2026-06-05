const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

function parseUsdc(value, fallback) {
  const text = String(value || fallback || "").trim();
  return hre.ethers.parseUnits(text, 6);
}

function feeOverrides() {
  const gasPriceGwei = String(process.env.GAS_PRICE_GWEI || "").trim();
  if (gasPriceGwei) {
    return { gasPrice: hre.ethers.parseUnits(gasPriceGwei, "gwei") };
  }

  const maxFeeGwei = String(process.env.MAX_FEE_GWEI || "").trim();
  const maxPriorityFeeGwei = String(process.env.MAX_PRIORITY_FEE_GWEI || "").trim();
  if (!maxFeeGwei && !maxPriorityFeeGwei) return {};

  return {
    maxFeePerGas: hre.ethers.parseUnits(maxFeeGwei || "1", "gwei"),
    maxPriorityFeePerGas: hre.ethers.parseUnits(maxPriorityFeeGwei || "0.001", "gwei")
  };
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const network = await hre.ethers.provider.getNetwork();
  const chainId = Number(network.chainId);

  if (chainId !== 1) {
    throw new Error(`USDC factory deployment is currently intended for Ethereum mainnet. Connected chainId ${chainId}.`);
  }

  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;
  const platformFeeRecipient = process.env.PLATFORM_FEE_RECIPIENT || feeRecipient;
  const usdcAddress = process.env.USDC_ADDRESS || "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const feeBps = BigInt(process.env.FEE_BPS || "50");
  const launchFeeWei = process.env.LAUNCH_FEE_ETH ? hre.ethers.parseEther(process.env.LAUNCH_FEE_ETH) : hre.ethers.parseEther("0.0015");
  const virtualQuoteReserve = parseUsdc(process.env.USDC_VIRTUAL_RESERVE, "1500");
  const virtualTokenReserve = process.env.VIRTUAL_TOKEN_RESERVE
    ? hre.ethers.parseUnits(process.env.VIRTUAL_TOKEN_RESERVE, 18)
    : hre.ethers.parseUnits("1000000", 18);
  const graduationTargetQuote = parseUsdc(process.env.USDC_GRADUATION_TARGET, "36000");
  const dexRouter = process.env.DEX_ROUTER || "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D";

  console.log("Deploying MemeLaunchFactoryERC20Quote");
  console.log("Chain ID:", chainId);
  console.log("Deployer:", deployer.address);
  console.log("USDC:", usdcAddress);
  console.log("Launch fee ETH:", hre.ethers.formatEther(launchFeeWei));
  console.log("Virtual USDC reserve:", hre.ethers.formatUnits(virtualQuoteReserve, 6));
  console.log("Graduation target USDC:", hre.ethers.formatUnits(graduationTargetQuote, 6));
  const overrides = feeOverrides();
  if (overrides.maxFeePerGas) {
    console.log("Max fee gwei:", hre.ethers.formatUnits(overrides.maxFeePerGas, "gwei"));
    console.log("Priority fee gwei:", hre.ethers.formatUnits(overrides.maxPriorityFeePerGas, "gwei"));
  } else if (overrides.gasPrice) {
    console.log("Gas price gwei:", hre.ethers.formatUnits(overrides.gasPrice, "gwei"));
  }

  const Factory = await hre.ethers.getContractFactory("MemeLaunchFactoryERC20Quote");
  const factory = await Factory.deploy(
    feeRecipient,
    platformFeeRecipient,
    usdcAddress,
    feeBps,
    launchFeeWei,
    virtualQuoteReserve,
    virtualTokenReserve,
    graduationTargetQuote,
    dexRouter,
    overrides
  );
  await factory.waitForDeployment();
  const address = await factory.getAddress();

  const output = {
    chainId,
    quoteMode: "usdc",
    quoteAsset: {
      mode: "usdc",
      symbol: "USDC",
      name: "USD Coin",
      address: usdcAddress,
      decimals: 6,
      isNative: false
    },
    deployedAt: new Date().toISOString(),
    memeLaunchFactory: address,
    feeRecipient,
    platformFeeRecipient,
    feeBps: Number(feeBps),
    launchFeeWei: launchFeeWei.toString(),
    virtualQuoteReserve: virtualQuoteReserve.toString(),
    virtualTokenReserve: virtualTokenReserve.toString(),
    graduationTargetQuote: graduationTargetQuote.toString(),
    dexRouter,
    lpRecipient: platformFeeRecipient
  };

  const outPath = path.join(__dirname, "..", "frontend", "deployments", "1.usdc.json");
  fs.writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);
  console.log("USDC factory:", address);
  console.log("Wrote", outPath);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
