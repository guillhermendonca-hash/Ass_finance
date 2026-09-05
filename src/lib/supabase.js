import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

/** Falso quando o .env ainda não foi preenchido — a UI avisa em vez de quebrar. */
export const supabaseConfigurado = Boolean(url && anonKey)

export const supabase = supabaseConfigurado
  ? createClient(url, anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null
