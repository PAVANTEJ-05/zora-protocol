import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";

export default defineConfig({
  out: "package/wagmiGenerated.ts",
  plugins: [
    foundry({
      forge: {
        build: false,
      },
      include: [
        "Coin",
        "CoinV4",
        "CreatorCoin",
        "ZoraFactoryImpl",
        "IUniswapV3Pool",
        "BuySupplyWithSwapRouterHook",
        "IPoolConfigEncoding",
        "IUniversalRouter",
        "IPermit2",
        "AutoSwapper",
      ].map((contractName) => `${contractName}.json`),
    }),
  ],
});
