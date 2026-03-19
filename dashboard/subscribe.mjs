// Sends subscribeAll() directly with a fixed gas limit, bypassing eth_estimateGas.
// Run from chainguard/dashboard/:  node subscribe.mjs
import { createWalletClient, http, encodeFunctionData } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const RPC   = process.env.REACTIVE_LASNA_RPC
const PK    = process.env.REACTIVE_PRIVATE_KEY
const ADDR  = process.env.RSC_ADDR

if (!RPC || !PK || !ADDR) {
  console.error('Set REACTIVE_LASNA_RPC, REACTIVE_PRIVATE_KEY, and RSC_ADDR env vars')
  process.exit(1)
}

const account = privateKeyToAccount(PK)

const client = createWalletClient({
  account,
  transport: http(RPC),
})

const data = encodeFunctionData({
  abi: [{ name: 'subscribeAll', type: 'function', inputs: [], outputs: [], stateMutability: 'nonpayable' }],
  functionName: 'subscribeAll',
})

console.log('Sending subscribeAll() to', ADDR)
console.log('From:', account.address)

const hash = await client.sendTransaction({
  to: ADDR,
  data,
  gas: 500000n,          // fixed gas — skips eth_estimateGas
  gasPrice: 15000000000n, // 15 gwei — adjust if network rejects
})

console.log('Transaction sent:', hash)
console.log('Check on Reactive Network explorer for confirmation.')
