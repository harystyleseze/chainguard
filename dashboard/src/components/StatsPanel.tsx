import { useState, useEffect, useCallback } from 'react'
import { ADDRESSES, GUARD_HOOK_ABI, RISK_REGISTRY_ABI, unichainClient, formatFee } from '../constants'

interface Stats {
  baseFee: number
  surchargeFee: number
  suspiciousFee: number
  swapsSurcharged: bigint
  suspiciousNewSurcharged: bigint
  totalFlagged: bigint
  totalBlocked: bigint
  isPaused: boolean
  mevTaxObserved: bigint
}

function StatCard({ label, value, sub, highlight }: { label: string; value: string; sub?: string; highlight?: boolean }) {
  return (
    <div className={`rounded-xl p-4 border ${highlight ? 'bg-red-900/20 border-red-700/40' : 'bg-gray-800/60 border-gray-700'}`}>
      <div className="text-xs text-gray-400 mb-1">{label}</div>
      <div className={`text-2xl font-bold ${highlight ? 'text-red-400' : 'text-white'}`}>{value}</div>
      {sub && <div className="text-xs text-gray-500 mt-1">{sub}</div>}
    </div>
  )
}

export default function StatsPanel() {
  const [stats, setStats] = useState<Stats | null>(null)
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null)
  const [error, setError] = useState('')

  const fetchStats = useCallback(async () => {
    try {
      const [hookStats, totalBlocked] = await Promise.all([
        unichainClient.readContract({
          address: ADDRESSES.HOOK,
          abi: GUARD_HOOK_ABI,
          functionName: 'getProtocolStats',
          args: [],
        }),
        unichainClient.readContract({
          address: ADDRESSES.REGISTRY,
          abi: RISK_REGISTRY_ABI,
          functionName: 'totalBlocked',
          args: [],
        }),
      ])

      const [baseFee, surchargeFee, suspiciousFee, swapsSurcharged, suspiciousNewSurcharged, totalFlagged, isPaused, mevTaxObserved]
        = hookStats as [number, number, number, bigint, bigint, bigint, boolean, bigint]

      setStats({
        baseFee, surchargeFee, suspiciousFee,
        swapsSurcharged, suspiciousNewSurcharged,
        totalFlagged, totalBlocked: totalBlocked as bigint,
        isPaused, mevTaxObserved,
      })
      setLastUpdated(new Date())
      setError('')
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Failed to fetch stats')
    }
  }, [])

  useEffect(() => {
    fetchStats()
    const id = setInterval(fetchStats, 8000)
    return () => clearInterval(id)
  }, [fetchStats])

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-gray-200">Protocol Statistics</h2>
        <div className="flex items-center gap-2">
          {lastUpdated && (
            <span className="text-xs text-gray-500">Updated {lastUpdated.toLocaleTimeString()}</span>
          )}
          <span className="relative flex h-2 w-2">
            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
            <span className="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
          </span>
        </div>
      </div>

      {error && (
        <div className="rounded-lg bg-red-900/40 border border-red-700 px-4 py-3 text-sm text-red-300">{error}</div>
      )}

      {stats ? (
        <>
          {stats.isPaused && (
            <div className="rounded-lg bg-red-900/50 border border-red-600 px-4 py-3 text-sm font-semibold text-red-300 flex items-center gap-2">
              <span>⏸</span> Hook is PAUSED — all swaps are blocked
            </div>
          )}

          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
            <StatCard label="Base Fee (Clean)" value={formatFee(stats.baseFee)} sub="Normal swappers" />
            <StatCard label="Suspicious Fee" value={formatFee(stats.suspiciousFee)} sub="SuspiciousNew tier" />
            <StatCard label="Surcharge Fee" value={formatFee(stats.surchargeFee)} sub="Flagged tier" />
            <StatCard label="Swaps Surcharged" value={stats.swapsSurcharged.toString()} sub="Flagged-tier hits" />
            <StatCard label="SuspiciousNew Hits" value={stats.suspiciousNewSurcharged.toString()} sub="Taint victims taxed" />
            <StatCard label="MEV Tax Observed" value={`${Number(stats.mevTaxObserved) / 1e9} Gwei`} sub="Cumulative priority fees" />
            <StatCard label="Total Flagged" value={stats.totalFlagged.toString()} sub="Active in registry" />
            <StatCard label="Total Blocked" value={stats.totalBlocked.toString()} sub="Sanctioned / OFAC" highlight={stats.totalBlocked > 0n} />
            <StatCard label="Status" value={stats.isPaused ? 'PAUSED' : 'ACTIVE'} highlight={stats.isPaused} />
          </div>

          <div className="text-xs text-gray-600 mt-2">Auto-refreshes every 8 seconds</div>
        </>
      ) : !error ? (
        <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
          {Array.from({ length: 9 }).map((_, i) => (
            <div key={i} className="rounded-xl p-4 border bg-gray-800/30 border-gray-700 animate-pulse h-20" />
          ))}
        </div>
      ) : null}
    </div>
  )
}
