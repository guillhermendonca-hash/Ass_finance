import { createContext } from 'react'

/** Vive fora do .jsx para não quebrar o Fast Refresh do provider. */
export const AuthContext = createContext(null)
