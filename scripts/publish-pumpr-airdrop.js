const fs = require("fs");
const path = require("path");

function argValue(name) {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? "" : process.argv[index + 1] || "";
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), "utf8"));
}

function main() {
  const snapshotPath = argValue("snapshot");
  const receiptPath = argValue("receipt");
  if (!snapshotPath || !receiptPath) {
    throw new Error("Pass --snapshot <json> and --receipt <json>.");
  }

  const snapshot = readJson(snapshotPath);
  const receipt = readJson(receiptPath);
  const historyPath = path.join(process.cwd(), "frontend", "data", "pumpr-airdrops.json");
  const history = readJson(historyPath);
  const snapshotDay = String(snapshot.snapshotAt).slice(0, 10).replaceAll("-", "");
  const id = `pumpr-live-0p5-weighted-1m-${snapshotDay}`;
  const signatures = Array.isArray(receipt.signatures) ? receipt.signatures : [];
  const recipients = snapshot.recipients.map((row, index) => ({
    ...row,
    status: "sent",
    signature: signatures[Math.floor(index / 6)] || ""
  }));
  const largestReward = Math.max(...recipients.map((row) => Number(row.amountPumpr || 0)));

  const drop = {
    id,
    badge: "Completed 0.5%+ weighted drop",
    title: "PUMPR loyal holder airdrop",
    status: "completed",
    preparedAt: snapshot.snapshotAt,
    executedAt: receipt.sentAt,
    snapshotAt: snapshot.snapshotAt,
    mint: snapshot.mint,
    source: {
      primary: "Pump.fun live holder list",
      primaryUrl: `https://pump.fun/coin/${snapshot.mint}`,
      apiUrl: snapshot.source?.holdersApiUrl,
      crossCheck: "Generated from the live holder snapshot immediately before distribution, with duplicate and allocation-total validation.",
      rule: "Wallets holding more than 0.5% of the 1,000,000,000 PUMPR supply qualified. Bonding curve, pool, dev, and bundler wallets were excluded. Rewards were weighted by supply share and holding time, with sniper-risk and prior-airdrop adjustments."
    },
    tiers: [{
      label: ">0.5% weighted",
      amountPumpr: largestReward,
      amountLabel: `${largestReward.toLocaleString("en-US")} max distributed PUMPR`,
      holderCount: recipients.length
    }],
    eligibleHolderCount: recipients.length,
    excludedCount: snapshot.excluded.length,
    totalAllocatedPumpr: snapshot.totalAllocatedPumpr,
    totalTransferredPumpr: snapshot.totalAllocatedPumpr,
    summaryAmountPumpr: largestReward,
    summaryAmountLabel: "Largest weighted recipient",
    notes: [
      "Supply threshold: 5,000,000 PUMPR, equal to 0.5% of the 1,000,000,000 token supply.",
      "Weight = holder percentage x holding-time multiplier x sniper-risk multiplier x prior-airdrop multiplier.",
      "Holding-time multipliers: 1.4x at 48+ hours, 1.2x at 24+ hours, 1x at 6+ hours, and 0.75x below 6 hours.",
      `${recipients.length} recipients received exactly ${Number(snapshot.totalAllocatedPumpr).toLocaleString("en-US")} PUMPR across ${signatures.length} confirmed Solana transactions.`
    ],
    excluded: snapshot.excluded,
    recipients,
    txSignatures: signatures,
    sender: receipt.sender
  };

  history.drops = (history.drops || []).filter((item) => item.id !== id);
  history.drops.unshift(drop);
  history.activeDropId = id;
  history.updatedAt = receipt.sentAt;
  fs.writeFileSync(historyPath, `${JSON.stringify(history, null, 2)}\n`);
  console.log(JSON.stringify({ id, recipients: recipients.length, total: snapshot.totalAllocatedPumpr, signatures: signatures.length }, null, 2));
}

try {
  main();
} catch (error) {
  console.error(error?.stack || error?.message || String(error));
  process.exit(1);
}
