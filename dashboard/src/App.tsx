import { useState } from 'react'
import RiskChecker from './components/RiskChecker'
import AdminPanel from './components/AdminPanel'
import StatsPanel from './components/StatsPanel'
import BatchChecker from './components/BatchChecker'
import { ADDRESSES, shortAddr, CHAIN_IDS } from './constants'
import { useWallet } from './hooks/useWallet'

type Tab = 'stats' | 'checker' | 'batch' | 'admin'

const TABS: { id: Tab; label: string; icon: string }[] = [
  { id: 'stats',   label: 'Protocol Stats', icon: '📊' },
  { id: 'checker', label: 'Risk Checker',   icon: '🔍' },
  { id: 'batch',   label: 'Batch Scanner',  icon: '📋' },
  { id: 'admin',   label: 'Admin Panel',    icon: '🛡' },
]

export default function App() {
  const [tab, setTab] = useState<Tab>('stats')
  const { account, chainId, connected, connecting, connect, switchToUnichain } = useWallet()
  const onUnichain = chainId === CHAIN_IDS.UNICHAIN
  const shortA     = account ? shortAddr(account) : null

  return (
    <div className="min-h-screen bg-gray-950 text-gray-100">
      {/* Header */}
      <header className="border-b border-gray-800 bg-gray-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-4xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-full bg-gradient-to-br from-pink-500 to-purple-600 flex items-center justify-center text-white font-bold text-sm">
              CG
            </div>
            <div>
              <span className="font-semibold text-white">ChainGuard</span>
              <span className="ml-2 text-xs text-gray-500">Compliance Dashboard</span>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {connected && !onUnichain && (
              <button
                onClick={switchToUnichain}
                className="px-2.5 py-1 text-[11px] font-mono bg-yellow-500/10 text-yellow-400 border border-yellow-500/30 rounded hover:bg-yellow-500/20 transition-colors"
              >
                Switch to Unichain
              </button>
            )}
            {connected && onUnichain && (
              <span className="flex items-center gap-1.5 px-2.5 py-1 text-[11px] font-mono bg-emerald-500/10 text-emerald-400 border border-emerald-500/30 rounded">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 inline-block" />
                Unichain Sepolia
              </span>
            )}
            {account ? (
              <span className="px-2.5 py-1 text-[11px] font-mono bg-gray-800 border border-gray-700 rounded text-gray-300">
                {shortA}
              </span>
            ) : (
              <button
                onClick={connect}
                disabled={connecting}
                className="px-3 py-1.5 text-xs font-semibold bg-pink-600 hover:bg-pink-500 text-white rounded transition-colors disabled:opacity-50"
              >
                {connecting ? 'Connecting…' : 'Connect Wallet'}
              </button>
            )}
          </div>
        </div>
      </header>

      {/* Contract address bar */}
      <div className="bg-gray-900/40 border-b border-gray-800/50">
        <div className="max-w-4xl mx-auto px-4 py-2 flex flex-wrap gap-x-6 gap-y-1 text-xs text-gray-500">
          <span>Registry: <span className="font-mono text-gray-400">{shortAddr(ADDRESSES.REGISTRY)}</span></span>
          <span>Hook: <span className="font-mono text-gray-400">{shortAddr(ADDRESSES.HOOK)}</span></span>
          <span>Callback: <span className="font-mono text-gray-400">{shortAddr(ADDRESSES.CALLBACK)}</span></span>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6">
        {/* Tab bar */}
        <div className="flex gap-1 mb-6 bg-gray-900/60 rounded-xl p-1 border border-gray-800">
          {TABS.map(t => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`flex-1 flex items-center justify-center gap-2 py-2 px-3 rounded-lg text-sm font-medium transition-all ${
                tab === t.id
                  ? 'bg-pink-600 text-white shadow-lg shadow-pink-900/40'
                  : 'text-gray-400 hover:text-gray-200 hover:bg-gray-800/60'
              }`}
            >
              <span>{t.icon}</span>
              <span className="hidden sm:inline">{t.label}</span>
            </button>
          ))}
        </div>

        {/* Tab content */}
        <div className="bg-gray-900/30 rounded-2xl border border-gray-800 p-6">
          {tab === 'stats'   && <StatsPanel />}
          {tab === 'checker' && <RiskChecker />}
          {tab === 'batch'   && <BatchChecker />}
          {tab === 'admin'   && <AdminPanel account={account} chainId={chainId} onSwitchUnichain={switchToUnichain} />}
        </div>

        {/* Footer */}
        <div className="mt-6 text-center text-xs text-gray-600">
          ChainGuard · UHI8 Hookathon · Unichain Sepolia · Reactive Network
        </div>
      </div>
    </div>
  )
}
