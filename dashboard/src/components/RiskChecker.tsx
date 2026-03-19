import { useState } from 'react'
import {
  ADDRESSES, RISK_REGISTRY_ABI, unichainClient,
  RISK_LABELS, RISK_COLORS, RISK_DOTS,
  shortAddr, formatTs,
} from '../constants'

interface RiskInfo {
  level: number
  flaggedAt: bigint
  flaggedBy: string
  isWhitelisted: boolean
  isIdentityVerified: boolean
  expiresAt: bigint | null
}

export default function RiskChecker() {
  const [addr, setAddr] = useState('')
  const [info, setInfo] = useState<RiskInfo | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  async function lookup() {
    const trimmed = addr.trim() as `0x${string}`
    if (!/^0x[0-9a-fA-F]{40}$/.test(trimmed)) {
      setError('Invalid address')
      return
    }
    setLoading(true)
    setError('')
    setInfo(null)
    try {
      const [level, flaggedAt, flaggedBy, isWhitelisted, isIdentityVerified, expiryPeriod] =
        await Promise.all([
          unichainClient.readContract({ address: ADDRESSES.REGISTRY, abi: RISK_REGISTRY_ABI, functionName: 'getRiskLevel',       args: [trimmed] }),
          unichainClient.readContract({ address: ADDRESSES.REGISTRY, abi: RISK_REGISTRY_ABI, functionName: 'flaggedAt',           args: [trimmed] }),
          unichainClient.readContract({ address: ADDRESSES.REGISTRY, abi: RISK_REGISTRY_ABI, functionName: 'flaggedBy',           args: [trimmed] }),
          unichainClient.readContract({ address: ADDRESSES.REGISTRY, abi: RISK_REGISTRY_ABI, functionName: 'whitelist',           args: [trimmed] }),
          unichainClient.readContract({ address: ADDRESSES.REGISTRY, abi: RISK_REGISTRY_ABI, functionName: 'identityVerified',    args: [trimmed] }),
          unichainClient.readContract({ address: ADDRESSES.REGISTRY, abi: RISK_REGISTRY_ABI, functionName: 'suspiciousExpiryPeriod', args: [] }),
        ])

      const levelNum = Number(level)
      const expiresAt = levelNum === 1 && (flaggedAt as bigint) > 0n && (expiryPeriod as bigint) > 0n
        ? (flaggedAt as bigint) + (expiryPeriod as bigint)
        : null

      setInfo({
        level: levelNum,
        flaggedAt: flaggedAt as bigint,
        flaggedBy: flaggedBy as string,
        isWhitelisted: isWhitelisted as boolean,
        isIdentityVerified: isIdentityVerified as boolean,
        expiresAt,
      })
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Lookup failed')
    } finally {
      setLoading(false)
    }
  }

  const nowTs = BigInt(Math.floor(Date.now() / 1000))
  const expiryCountdown = info?.expiresAt != null
    ? info.expiresAt > nowTs
      ? `Expires in ${Math.floor(Number(info.expiresAt - nowTs) / 3600)}h ${Math.floor((Number(info.expiresAt - nowTs) % 3600) / 60)}m`
      : 'Expired (eligible to clear)'
    : null

  return (
    <div className="space-y-4">
      <h2 className="text-lg font-semibold text-gray-200">Risk Checker</h2>
      <p className="text-sm text-gray-400">Look up any address's compliance risk level — no wallet required.</p>

      <div className="flex gap-2">
        <input
          type="text"
          value={addr}
          onChange={e => setAddr(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && lookup()}
          placeholder="0x..."
          className="flex-1 rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm font-mono text-gray-100 placeholder-gray-500 focus:outline-none focus:border-pink-500"
        />
        <button
          onClick={lookup}
          disabled={loading}
          className="px-5 py-2 rounded-lg bg-pink-600 hover:bg-pink-500 text-white text-sm font-medium disabled:opacity-50 transition-colors"
        >
          {loading ? 'Checking…' : 'Check'}
        </button>
      </div>

      {error && (
        <div className="rounded-lg bg-red-900/40 border border-red-700 px-4 py-3 text-sm text-red-300">
          {error}
        </div>
      )}

      {info && (
        <div className="rounded-xl bg-gray-800/60 border border-gray-700 p-5 space-y-4">
          {/* Risk badge */}
          <div className="flex items-center gap-3">
            <span className="text-2xl">{RISK_DOTS[info.level]}</span>
            <div>
              <span className={`inline-block px-3 py-1 rounded-full text-sm font-semibold ${RISK_COLORS[info.level]}`}>
                {RISK_LABELS[info.level]}
              </span>
              {info.isWhitelisted && (
                <span className="ml-2 inline-block px-2 py-0.5 rounded-full text-xs bg-blue-600 text-white">Whitelisted</span>
              )}
              {info.isIdentityVerified && (
                <span className="ml-2 inline-block px-2 py-0.5 rounded-full text-xs bg-purple-600 text-white">KYC Verified</span>
              )}
            </div>
          </div>

          {/* Metadata */}
          <div className="grid grid-cols-2 gap-3 text-sm">
            <div className="bg-gray-900/60 rounded-lg p-3">
              <div className="text-gray-400 text-xs mb-1">Flagged At</div>
              <div className="font-mono text-gray-200">{formatTs(info.flaggedAt)}</div>
            </div>
            <div className="bg-gray-900/60 rounded-lg p-3">
              <div className="text-gray-400 text-xs mb-1">Flagged By</div>
              <div className="font-mono text-gray-200">
                {info.flaggedBy === '0x0000000000000000000000000000000000000000' ? '—' : shortAddr(info.flaggedBy)}
              </div>
            </div>
          </div>

          {/* SuspiciousNew expiry countdown */}
          {expiryCountdown && (
            <div className="rounded-lg bg-yellow-900/30 border border-yellow-700/50 px-4 py-3 text-sm text-yellow-300">
              <span className="font-medium">Expiry: </span>{expiryCountdown}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
