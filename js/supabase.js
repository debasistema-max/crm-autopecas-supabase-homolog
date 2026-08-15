let supabaseClient = null;

function initSupabase() {
  if (!APP_CONFIG.supabasePreferred) return false;
  if (!window.supabase || !SUPABASE_CONFIG.url || !SUPABASE_CONFIG.anonKey) return false;
  supabaseClient = window.supabase.createClient(SUPABASE_CONFIG.url, SUPABASE_CONFIG.anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
  return true;
}

function isSupabaseReady() {
  return !!supabaseClient;
}

function isSupabaseMode() {
  return isSupabaseReady();
}

initSupabase();
