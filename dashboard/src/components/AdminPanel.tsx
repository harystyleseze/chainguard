import { useState } from 'react'
import {
  ADDRESSES, RISK_REGISTRY_ABI, GUARD_HOOK_ABI, CHAIN_IDS,
  encodeCall, sendTx, waitForTx,
} from '../constants'

type Action =
  | 'block'
  | 'unblock'
  | 'whitelist_on'
  | 'whitelist_off'
  | 'kyc_on'
  | 'kyc_off'
  | 'flag'
  | 'pause'
  | 'unpause'

interface ActionConfig {
  label: string
  description: string
  needsAddress: boolean
  needsSource?: boolean
  color: string
}

const ACTIONS: Record<Action, ActionConfig> = {
  block:        { label: 'Block Address',       description: 'Set to Blocked (reverts all swaps)',           needsAddress: true,  color: 'bg-red-700 hover:bg-red-600' },
  unblock:      { label: 'Clear / Unblock',      description: 'Reset to Clean and clear metadata',           needsAddress: true,  color: 'bg-emerald-700 hover:bg-emerald-600' },
  whitelist_on: { label: 'Add to Whitelist',     description: 'Bypass all risk checks (base fee always)',    needsAddress: true,  color: 'bg-blue-700 hover:bg-blue-600' },
  whitelist_off:{ label: 'Remove from Whitelist',description: 'Remove whitelist bypass',                     needsAddress: true,  color: 'bg-blue-900 hover:bg-blue-800' },
  kyc_on:       { label: 'Mark KYC Verified',    description: 'EAS/World ID positive identity layer',        needsAddress: true,  color: 'bg-purple-700 hover:bg-purple-600' },
  kyc_off:      { label: 'Revoke KYC',           description: 'Remove identity-verified status',             needsAddress: true,  color: 'bg-purple-900 hover:bg-purple-800' },
  flag:         { label: 'Flag Address',          description: 'Set to Flagged (3% surcharge)',              needsAddress: true, needsSource: true, color: 'bg-orange-700 hover:bg-orange-600' },
  pause:        { label: 'Pause Hook',            description: 'Emergency: block all swaps',                  needsAddress: false, color: 'bg-red-900 hover:bg-red-800' },
  unpause:      { label: 'Unpause Hook',          description: 'Resume normal operation',                     needsAddress: false, color: 'bg-emerald-900 hover:bg-emerald-800' },
}

interface AdminPanelProps {
  account: `0x${string}` | null
  chainId: number | null
  onSwitchUnichain: () => void
}

export default function AdminPanel({ account, chainId, onSwitchUnichain }: AdminPanelProps) {
  const [selectedAction, setSelectedAction] = useState<Action>('block')
  const [targetAddr, setTargetAddr] = useState('')
  const [sourceAddr, setSourceAddr] = useState('')
  const [status, setStatus] = useState<{ type: 'idle' | 'pending' | 'success' | 'error'; message: string }>({ type: 'idle', message: '' })

  async function execute() {
    if (!account) {
      setStatus({ type: 'error', message: 'Connect wallet first' })
      return
    }
    if (chainId !== CHAIN_IDS.UNICHAIN) {
      setStatus({ type: 'error', message: 'Switch to Unichain Sepolia first' })
      onSwitchUnichain()
      return
    }
    const config = ACTIONS[selectedAction]
    if (config.needsAddress && !/^0x[0-9a-fA-F]{40}$/.test(targetAddr.trim())) {
      setStatus({ type: 'error', message: 'Invalid target address' })
      return
    }
    if (config.needsSource && !/^0x[0-9a-fA-F]{40}$/.test(sourceAddr.trim())) {
      setStatus({ type: 'error', message: 'Invalid source address' })
      return
    }

    setStatus({ type: 'pending', message: 'Sending transaction…' })
    try {
      let calldata: `0x${string}`
      let to: `0x${string}`

      switch (selectedAction) {
        case 'block':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'addToBlacklist', [targetAddr.trim()])
          to = ADDRESSES.REGISTRY
          break
        case 'unblock':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'removeFromBlacklist', [targetAddr.trim()])
          to = ADDRESSES.REGISTRY
          break
        case 'whitelist_on':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'setWhitelist', [targetAddr.trim(), true])
          to = ADDRESSES.REGISTRY
          break
        case 'whitelist_off':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'setWhitelist', [targetAddr.trim(), false])
          to = ADDRESSES.REGISTRY
          break
        case 'kyc_on':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'setIdentityVerified', [targetAddr.trim(), true])
          to = ADDRESSES.REGISTRY
          break
        case 'kyc_off':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'setIdentityVerified', [targetAddr.trim(), false])
          to = ADDRESSES.REGISTRY
          break
        case 'flag':
          calldata = encodeCall(RISK_REGISTRY_ABI, 'flagAddressDirect', [targetAddr.trim(), sourceAddr.trim() || account])
          to = ADDRESSES.REGISTRY
          break
        case 'pause':
          calldata = encodeCall(GUARD_HOOK_ABI, 'pause', [])
          to = ADDRESSES.HOOK
          break
        case 'unpause':
          calldata = encodeCall(GUARD_HOOK_ABI, 'unpause', [])
          to = ADDRESSES.HOOK
          break
        default:
          throw new Error('Unknown action')
      }

      setStatus({ type: 'pending', message: 'Sending transaction…' })
      const hash = await sendTx(to, calldata, account)
      setStatus({ type: 'pending', message: `Waiting for confirmation… (${hash.slice(0, 10)}…)` })
      await waitForTx(hash)
      setStatus({ type: 'success', message: `${config.label} confirmed! tx: ${hash.slice(0, 18)}…` })
    } catch (e: unknown) {
      setStatus({ type: 'error', message: e instanceof Error ? e.message : 'Transaction failed' })
    }
  }

  const config = ACTIONS[selectedAction]

  return (
    <div className="space-y-5">
      <div>
        <h2 className="text-lg font-semibold text-gray-200">Admin Panel</h2>
        <p className="text-sm text-gray-400 mt-1">Owner-only actions. Requires MetaMask on Unichain Sepolia (Chain 1301).</p>
        {!account && (
          <div className="mt-2 text-xs text-yellow-400 bg-yellow-900/20 border border-yellow-800 rounded px-3 py-2">
            Connect wallet (button in header) to execute admin actions.
          </div>
        )}
        {account && chainId !== CHAIN_IDS.UNICHAIN && (
          <div className="mt-2 text-xs text-yellow-400 bg-yellow-900/20 border border-yellow-800 rounded px-3 py-2">
            Switch to Unichain Sepolia — click "Switch to Unichain" in the header.
          </div>
        )}
        {account && chainId === CHAIN_IDS.UNICHAIN && (
          <div className="mt-2 text-xs text-emerald-400 bg-emerald-900/20 border border-emerald-800 rounded px-3 py-2">
            ✓ Connected on Unichain Sepolia — ready to execute.
          </div>
        )}
      </div>

      {/* Action picker */}
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
        {(Object.entries(ACTIONS) as [Action, ActionConfig][]).map(([key, cfg]) => (
          <button
            key={key}
            onClick={() => setSelectedAction(key)}
            className={`text-left p-3 rounded-lg border transition-all text-sm ${
              selectedAction === key
                ? 'border-pink-500 bg-pink-900/20 text-white'
                : 'border-gray-700 bg-gray-800/40 text-gray-400 hover:border-gray-500 hover:text-gray-200'
            }`}
          >
            <div className="font-medium">{cfg.label}</div>
            <div className="text-xs mt-0.5 opacity-70">{cfg.description}</div>
          </button>
        ))}
      </div>

      {/* Inputs */}
      <div className="space-y-3">
        {config.needsAddress && (
          <div>
            <label className="block text-xs text-gray-400 mb-1">Target Address</label>
            <input
              type="text"
              value={targetAddr}
              onChange={e => setTargetAddr(e.target.value)}
              placeholder="0x..."
              className="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm font-mono text-gray-100 placeholder-gray-500 focus:outline-none focus:border-pink-500"
            />
          </div>
        )}
        {config.needsSource && (
          <div>
            <label className="block text-xs text-gray-400 mb-1">Source Address (optional — defaults to your wallet)</label>
            <input
              type="text"
              value={sourceAddr}
              onChange={e => setSourceAddr(e.target.value)}
              placeholder="0x... or leave blank"
              className="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm font-mono text-gray-100 placeholder-gray-500 focus:outline-none focus:border-pink-500"
            />
          </div>
        )}
      </div>

      <button
        onClick={execute}
        disabled={status.type === 'pending'}
        className={`w-full py-3 rounded-lg text-white text-sm font-semibold disabled:opacity-50 transition-colors ${config.color}`}
      >
        {status.type === 'pending' ? 'Processing…' : config.label}
      </button>

      {status.type !== 'idle' && (
        <div className={`rounded-lg px-4 py-3 text-sm border ${
          status.type === 'success' ? 'bg-emerald-900/30 border-emerald-700 text-emerald-300' :
          status.type === 'error'   ? 'bg-red-900/30 border-red-700 text-red-300' :
                                      'bg-blue-900/30 border-blue-700 text-blue-300'
        }`}>
          {status.type === 'pending' && <span className="mr-2 inline-block animate-spin">⟳</span>}
          {status.message}
        </div>
      )}
    </div>
  )
}
