import { useState } from 'react'
import { ADDRESSES, RISK_REGISTRY_ABI, unichainClient, RISK_LABELS, RISK_COLORS, RISK_DOTS, shortAddr } from '../constants'

interface Row {
  address: string
  level: number
}

export default function BatchChecker() {
  const [input, setInput] = useState('')
  const [rows, setRows] = useState<Row[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  async function scan() {
    const lines = input.split('\n').map(l => l.trim()).filter(l => /^0x[0-9a-fA-F]{40}$/.test(l))
    if (lines.length === 0) {
      setError('No valid addresses found. Enter one 0x address per line.')
      return
    }
    if (lines.length > 50) {
      setError('Max 50 addresses at once.')
      return
    }
    setLoading(true)
    setError('')
    setRows([])
    try {
      const levels = await unichainClient.readContract({
        address: ADDRESSES.REGISTRY,
        abi: RISK_REGISTRY_ABI,
        functionName: 'batchGetRiskLevel',
        args: [lines as `0x${string}`[]],
      }) as number[]

      setRows(lines.map((address, i) => ({ address, level: Number(levels[i]) })))
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Batch scan failed')
    } finally {
      setLoading(false)
    }
  }

  const summary = rows.reduce((acc, r) => {
    acc[r.level] = (acc[r.level] || 0) + 1
    return acc
  }, {} as Record<number, number>)

  return (
    <div className="space-y-4">
      <h2 className="text-lg font-semibold text-gray-200">Batch Risk Scanner</h2>
      <p className="text-sm text-gray-400">Paste up to 50 addresses (one per line) for a bulk compliance check.</p>

      <textarea
        value={input}
        onChange={e => setInput(e.target.value)}
        rows={6}
        placeholder={'0x5BE95B67a2bb0952fc8cb019A464819e9BC4eD5D\n0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045\n...'}
        className="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-sm font-mono text-gray-100 placeholder-gray-500 focus:outline-none focus:border-pink-500 resize-none"
      />

      <button
        onClick={scan}
        disabled={loading}
        className="px-6 py-2 rounded-lg bg-pink-600 hover:bg-pink-500 text-white text-sm font-medium disabled:opacity-50 transition-colors"
      >
        {loading ? 'Scanning…' : 'Scan All'}
      </button>

      {error && (
        <div className="rounded-lg bg-red-900/40 border border-red-700 px-4 py-3 text-sm text-red-300">{error}</div>
      )}

      {rows.length > 0 && (
        <div className="space-y-3">
          {/* Summary row */}
          <div className="flex flex-wrap gap-2">
            {Object.entries(summary).map(([level, count]) => (
              <span key={level} className={`inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-medium ${RISK_COLORS[Number(level)]}`}>
                {RISK_DOTS[Number(level)]} {RISK_LABELS[Number(level)]}: {count}
              </span>
            ))}
          </div>

          {/* Table */}
          <div className="rounded-xl overflow-hidden border border-gray-700">
            <table className="w-full text-sm">
              <thead>
                <tr className="bg-gray-800 text-left">
                  <th className="px-4 py-2 text-xs text-gray-400 font-medium">#</th>
                  <th className="px-4 py-2 text-xs text-gray-400 font-medium">Address</th>
                  <th className="px-4 py-2 text-xs text-gray-400 font-medium">Risk Level</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row, i) => (
                  <tr key={row.address} className={i % 2 === 0 ? 'bg-gray-900/40' : 'bg-gray-900/20'}>
                    <td className="px-4 py-2 text-gray-500 text-xs">{i + 1}</td>
                    <td className="px-4 py-2 font-mono text-gray-200 text-xs">
                      <span className="hidden sm:inline">{row.address}</span>
                      <span className="sm:hidden">{shortAddr(row.address)}</span>
                    </td>
                    <td className="px-4 py-2">
                      <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${RISK_COLORS[row.level]}`}>
                        {RISK_DOTS[row.level]} {RISK_LABELS[row.level]}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  )
}
