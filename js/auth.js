let inMemorySession = null;

function getStoredSession() {
  return inMemorySession;
}

function setStoredSession(session) {
  if (!session) {
    inMemorySession = null;
    return;
  }
  inMemorySession = {
    sessionId: session.sessionId || null,
    usuario: session.usuario || '',
    nome: session.nome || '',
    email: session.email || '',
    perfil: session.perfil || '',
    modules: Array.isArray(session.modules) ? [...session.modules] : []
  };
}

function clearStoredSession() {
  inMemorySession = null;
  try {
    sessionStorage.removeItem(APP_CONFIG.sessionKey);
  } catch (error) {
    // Remove apenas o cache legado; a sessão real é administrada pelo Supabase Auth.
  }
}

function getSessionId() {
  const stored = getStoredSession();
  return stored && (stored.sessionId || stored.token);
}

async function validateCurrentSession() {
  const supabaseSession = await supabaseValidateSession();
  if (supabaseSession) {
    setStoredSession(supabaseSession);
    return supabaseSession;
  }
  return null;
}

document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('loginForm');
  if (!form) return;

  const message = document.getElementById('loginMessage');
  const button = document.getElementById('loginButton');

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    message.textContent = '';
    button.disabled = true;
    button.textContent = 'Entrando...';
    try {
      const usuario = document.getElementById('usuario').value;
      const senha = document.getElementById('senha').value;
      const data = await supabaseLogin(usuario, senha);
      const session = Object.assign({}, data.session || {}, {
        sessionId: data.sessionId || data.token || (data.session && data.session.token),
        modules: Array.isArray(data.modules) ? data.modules : []
      });
      setStoredSession(session);
      window.location.href = 'app.html';
    } catch (error) {
      message.textContent = error.message;
    } finally {
      button.disabled = false;
      button.textContent = 'Entrar';
    }
  });
});
