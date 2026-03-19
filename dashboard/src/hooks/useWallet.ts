import { useState, useEffect, useCallback } from 'react'
import { CHAIN_IDS } from '../constants'

export interface WalletState {
  account:    `0x${string}` | null
  chainId:    number | null
  connected:  boolean
  connecting: boolean
  error:      string | null
}

export interface WalletActions {
  connect:          () => Promise<void>
  switchToUnichain: () => Promise<void>
}

export function useWallet(): WalletState & WalletActions {
  const [state, setState] = useState<WalletState>({
    account:    null,
    chainId:    null,
    connected:  false,
    connecting: false,
    error:      null,
  })

  const readState = useCallback(async () => {
    if (!window.ethereum) return
    try {
      const [accounts, chainIdHex] = await Promise.all([
        window.ethereum.request({ method: 'eth_accounts' }) as Promise<string[]>,
        window.ethereum.request({ method: 'eth_chainId'  }) as Promise<string>,
      ])
      const account = accounts[0] as `0x${string}` | undefined
      const chainId = parseInt(chainIdHex, 16)
      setState(prev => ({ ...prev, account: account ?? null, chainId, connected: !!account }))
    } catch { /* ignore */ }
  }, [])

  useEffect(() => {
    readState()
    if (!window.ethereum) return
    const onAccounts = (accounts: unknown) => {
      const list = accounts as string[]
      setState(prev => ({
        ...prev,
        account:   list[0] as `0x${string}` | undefined ?? null,
        connected: list.length > 0,
      }))
    }
    const onChain = (chainIdHex: unknown) => {
      setState(prev => ({ ...prev, chainId: parseInt(chainIdHex as string, 16) }))
    }
    window.ethereum.on('accountsChanged', onAccounts)
    window.ethereum.on('chainChanged', onChain)
    return () => {
      window.ethereum?.removeListener('accountsChanged', onAccounts)
      window.ethereum?.removeListener('chainChanged', onChain)
    }
  }, [readState])

  const connect = useCallback(async () => {
    if (!window.ethereum) {
      setState(prev => ({ ...prev, error: 'MetaMask not found' }))
      return
    }
    setState(prev => ({ ...prev, connecting: true, error: null }))
    try {
      const accounts   = await window.ethereum.request({ method: 'eth_requestAccounts' }) as `0x${string}`[]
      const chainIdHex = await window.ethereum.request({ method: 'eth_chainId' }) as string
      setState({
        account:    accounts[0] ?? null,
        chainId:    parseInt(chainIdHex, 16),
        connected:  accounts.length > 0,
        connecting: false,
        error:      null,
      })
    } catch (err) {
      setState(prev => ({
        ...prev,
        connecting: false,
        error: err instanceof Error ? err.message : 'Connection failed',
      }))
    }
  }, [])

  const switchToUnichain = useCallback(async () => {
    try {
      await window.ethereum?.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: `0x${CHAIN_IDS.UNICHAIN.toString(16)}` }],
      })
    } catch {
      try {
        await window.ethereum?.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: '0x515',
            chainName: 'Unichain Sepolia',
            nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
            rpcUrls: ['https://sepolia.unichain.org'],
            blockExplorerUrls: ['https://unichain-sepolia.blockscout.com'],
          }],
        })
      } catch (addErr) {
        setState(prev => ({ ...prev, error: addErr instanceof Error ? addErr.message : 'Switch failed' }))
      }
    }
  }, [])

  return { ...state, connect, switchToUnichain }
}
