import { createPublicClient, http, encodeFunctionData } from 'viem'
import type { Abi } from 'viem'

// ─── Contract Addresses ────────────────────────────────────────────────────

export const ADDRESSES = {
  REGISTRY:     '0x784b55846c052500c8fda5b36965ed3b8ca87792' as `0x${string}`,
  HOOK:         '0xa0510994afa4c109dcc6886ddc56446ec4eeeec0' as `0x${string}`,
  CALLBACK:     '0xf936be2d36418f1e1d5d7ee58af4bbc6120b557b' as `0x${string}`,
  POOL_MANAGER: '0x00B036B58a818B1BC34d502D3fE730Db729e62AC' as `0x${string}`,
}

export const CHAIN_IDS = { UNICHAIN: 1301 }

// ─── Unichain Sepolia viem client ─────────────────────────────────────────

export const unichainClient = createPublicClient({
  chain: {
    id: CHAIN_IDS.UNICHAIN,
    name: 'Unichain Sepolia',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: ['https://sepolia.unichain.org'] } },
  },
  transport: http('https://sepolia.unichain.org'),
})

// ─── ABIs ─────────────────────────────────────────────────────────────────

export const RISK_REGISTRY_ABI = [
  // Read
  { name: 'getRiskLevel',       type: 'function', stateMutability: 'view',       inputs: [{ name: 'account',   type: 'address' }],                          outputs: [{ type: 'uint8' }] },
  { name: 'batchGetRiskLevel',  type: 'function', stateMutability: 'view',       inputs: [{ name: 'accounts',  type: 'address[]' }],                         outputs: [{ type: 'uint8[]' }] },
  { name: 'riskLevels',         type: 'function', stateMutability: 'view',       inputs: [{ name: '',          type: 'address' }],                           outputs: [{ type: 'uint8' }] },
  { name: 'flaggedAt',          type: 'function', stateMutability: 'view',       inputs: [{ name: 'account',   type: 'address' }],                           outputs: [{ type: 'uint256' }] },
  { name: 'flaggedBy',          type: 'function', stateMutability: 'view',       inputs: [{ name: 'account',   type: 'address' }],                           outputs: [{ type: 'address' }] },
  { name: 'whitelist',          type: 'function', stateMutability: 'view',       inputs: [{ name: 'account',   type: 'address' }],                           outputs: [{ type: 'bool' }] },
  { name: 'identityVerified',   type: 'function', stateMutability: 'view',       inputs: [{ name: 'account',   type: 'address' }],                           outputs: [{ type: 'bool' }] },
  { name: 'totalFlagged',       type: 'function', stateMutability: 'view',       inputs: [],                                                                  outputs: [{ type: 'uint256' }] },
  { name: 'totalBlocked',       type: 'function', stateMutability: 'view',       inputs: [],                                                                  outputs: [{ type: 'uint256' }] },
  { name: 'suspiciousExpiryPeriod', type: 'function', stateMutability: 'view',   inputs: [],                                                                  outputs: [{ type: 'uint256' }] },
  // Write
  { name: 'addToBlacklist',     type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'target',    type: 'address' }],                           outputs: [] },
  { name: 'removeFromBlacklist',type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'target',    type: 'address' }],                           outputs: [] },
  { name: 'setWhitelist',       type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'account',   type: 'address' }, { name: 'status', type: 'bool' }], outputs: [] },
  { name: 'setIdentityVerified',type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'account',   type: 'address' }, { name: 'status', type: 'bool' }], outputs: [] },
  { name: 'flagAddressDirect',  type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'target',    type: 'address' }, { name: 'source', type: 'address' }], outputs: [] },
  { name: 'setCallbackContract',type: 'function', stateMutability: 'nonpayable', inputs: [{ name: '_cb',       type: 'address' }],                           outputs: [] },
] as const satisfies Abi

export const GUARD_HOOK_ABI = [
  // Read
  { name: 'getProtocolStats', type: 'function', stateMutability: 'view', inputs: [],
    outputs: [
      { name: '_baseFee',              type: 'uint24'  },
      { name: '_surchargeFee',         type: 'uint24'  },
      { name: '_suspiciousFee',        type: 'uint24'  },
      { name: 'swapsSurcharged',       type: 'uint256' },
      { name: 'suspiciousNewSurcharged', type: 'uint256' },
      { name: 'totalFlagged',          type: 'uint256' },
      { name: 'isPaused',              type: 'bool'    },
      { name: 'mevTaxObserved',        type: 'uint256' },
    ]
  },
  { name: 'paused',     type: 'function', stateMutability: 'view',       inputs: [], outputs: [{ type: 'bool' }] },
  { name: 'baseFee',    type: 'function', stateMutability: 'view',       inputs: [], outputs: [{ type: 'uint24' }] },
  // Write
  { name: 'pause',      type: 'function', stateMutability: 'nonpayable', inputs: [], outputs: [] },
  { name: 'unpause',    type: 'function', stateMutability: 'nonpayable', inputs: [], outputs: [] },
] as const satisfies Abi

// ─── Risk Level Helpers ───────────────────────────────────────────────────

export const RISK_LABELS: Record<number, string> = {
  0: 'Clean',
  1: 'SuspiciousNew',
  2: 'Flagged',
  3: 'Blocked',
}

export const RISK_COLORS: Record<number, string> = {
  0: 'bg-emerald-600 text-white',
  1: 'bg-yellow-500 text-black',
  2: 'bg-orange-500 text-white',
  3: 'bg-red-600 text-white',
}

export const RISK_DOTS: Record<number, string> = {
  0: '🟢',
  1: '🟡',
  2: '🟠',
  3: '🔴',
}

// ─── MetaMask Helpers ────────────────────────────────────────────────────

declare global {
  interface Window {
    ethereum?: {
      request:        (args: { method: string; params?: unknown[] }) => Promise<unknown>
      on:             (event: string, handler: (data: unknown) => void) => void
      removeListener: (event: string, handler: (data: unknown) => void) => void
    }
  }
}

export async function switchToUnichain(): Promise<void> {
  if (!window.ethereum) throw new Error('MetaMask not found')
  try {
    await window.ethereum.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: '0x515' }],
    })
  } catch {
    await window.ethereum.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: '0x515',
        chainName: 'Unichain Sepolia',
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: ['https://sepolia.unichain.org'],
        blockExplorerUrls: ['https://unichain-sepolia.blockscout.com'],
      }],
    })
  }
}

export async function getAccount(): Promise<`0x${string}`> {
  if (!window.ethereum) throw new Error('MetaMask not found')
  const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' }) as `0x${string}`[]
  return accounts[0]
}

export function encodeCall(abi: Abi, fn: string, args: unknown[]): `0x${string}` {
  return encodeFunctionData({ abi, functionName: fn, args } as Parameters<typeof encodeFunctionData>[0])
}

export async function sendTx(to: `0x${string}`, data: `0x${string}`, from: `0x${string}`): Promise<`0x${string}`> {
  if (!window.ethereum) throw new Error('MetaMask not found')
  const hash = await window.ethereum.request({
    method: 'eth_sendTransaction',
    params: [{ from, to, data, gas: '0x493E0' }],
  }) as `0x${string}`
  return hash
}

export async function waitForTx(hash: `0x${string}`): Promise<void> {
  for (let i = 0; i < 60; i++) {
    await new Promise(r => setTimeout(r, 2000))
    try {
      const receipt = await unichainClient.getTransactionReceipt({ hash })
      if (receipt.status === 'reverted') throw new Error('Transaction reverted')
      return
    } catch (e: unknown) {
      if (e instanceof Error && e.message === 'Transaction reverted') throw e
      // not yet mined — keep polling
    }
  }
  throw new Error('Transaction timeout')
}

export function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export function formatFee(bps: number): string {
  return `${(bps / 10000 * 100).toFixed(2)}%`
}

export function formatTs(ts: bigint): string {
  if (ts === 0n) return '—'
  return new Date(Number(ts) * 1000).toLocaleString()
}
