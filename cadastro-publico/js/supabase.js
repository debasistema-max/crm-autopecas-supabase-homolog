let portalSupabase = null;

function initPortalSupabase() {
  if (!window.supabase || !PORTAL_SUPABASE_CONFIG.url || !PORTAL_SUPABASE_CONFIG.anonKey) return false;
  portalSupabase = window.supabase.createClient(PORTAL_SUPABASE_CONFIG.url, PORTAL_SUPABASE_CONFIG.anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false
    }
  });
  return true;
}

function isPortalSupabaseReady() {
  return !!portalSupabase;
}

initPortalSupabase();
