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
  const recoveryForm = document.getElementById('recoveryRequestForm');
  const resetForm = document.getElementById('passwordResetForm');
  const recoveryMessage = document.getElementById('recoveryRequestMessage');
  const resetMessage = document.getElementById('passwordResetMessage');
  const cardHeader = document.querySelector('.login-card__header');
  const customerPortalLink = document.querySelector('.customer-portal-link');
  const hashParams = new URLSearchParams(location.hash.replace(/^#/, ''));
  const queryParams = new URLSearchParams(location.search);
  const isRecoveryLink = hashParams.get('type') === 'recovery' || queryParams.get('type') === 'recovery';
  const recoveryLinkError = hashParams.get('error_description') || queryParams.get('error_description');

  const showView = (target) => {
    form.hidden = target !== 'login';
    recoveryForm.hidden = target !== 'recovery';
    resetForm.hidden = target !== 'reset';
    cardHeader.hidden = target !== 'login';
    customerPortalLink.hidden = target !== 'login';
  };

  const cleanRecoveryUrl = () => {
    if (!history.replaceState) return;
    history.replaceState({}, document.title, location.pathname);
  };

  const showPasswordReset = () => {
    resetMessage.textContent = '';
    showView('reset');
    cleanRecoveryUrl();
    document.getElementById('newPassword').focus();
  };

  document.getElementById('forgotPasswordButton').addEventListener('click', () => {
    const typedLogin = document.getElementById('usuario').value.trim();
    document.getElementById('recoveryEmail').value = typedLogin.includes('@') ? typedLogin : '';
    recoveryMessage.textContent = '';
    showView('recovery');
    document.getElementById('recoveryEmail').focus();
  });

  document.querySelectorAll('[data-back-to-login]').forEach((backButton) => {
    backButton.addEventListener('click', () => {
      recoveryMessage.textContent = '';
      showView('login');
      document.getElementById('usuario').focus();
    });
  });

  recoveryForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const requestButton = document.getElementById('recoveryRequestButton');
    const email = document.getElementById('recoveryEmail').value.trim().toLowerCase();
    recoveryMessage.textContent = '';
    requestButton.disabled = true;
    requestButton.textContent = 'Enviando...';
    try {
      const redirectTo = location.origin + location.pathname;
      const { error } = await supabaseClient.auth.resetPasswordForEmail(email, { redirectTo });
      if (error) throw error;
      recoveryMessage.textContent = 'Se o e-mail estiver cadastrado, o link de recuperação será enviado. Verifique também o Spam.';
    } catch (error) {
      recoveryMessage.textContent = 'Não foi possível enviar o link agora. Aguarde um instante e tente novamente.';
    } finally {
      requestButton.disabled = false;
      requestButton.textContent = 'Enviar link';
    }
  });

  resetForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const resetButton = document.getElementById('passwordResetButton');
    const password = document.getElementById('newPassword').value;
    const confirmation = document.getElementById('confirmNewPassword').value;
    resetMessage.textContent = '';
    if (password.length < 8 || !/[A-Za-z]/.test(password) || !/[0-9]/.test(password)) {
      resetMessage.textContent = 'Use no mínimo 8 caracteres, com pelo menos uma letra e um número.';
      return;
    }
    if (password !== confirmation) {
      resetMessage.textContent = 'As senhas não conferem.';
      return;
    }
    resetButton.disabled = true;
    resetButton.textContent = 'Salvando...';
    try {
      const { error } = await supabaseClient.auth.updateUser({ password });
      if (error) throw error;
      await supabaseClient.auth.signOut();
      cleanRecoveryUrl();
      resetForm.reset();
      showView('login');
      message.textContent = 'Senha atualizada. Entre com seu usuário e a nova senha.';
    } catch (error) {
      resetMessage.textContent = 'Não foi possível atualizar a senha. Solicite um novo link de recuperação.';
    } finally {
      resetButton.disabled = false;
      resetButton.textContent = 'Salvar nova senha';
    }
  });

  supabaseClient.auth.onAuthStateChange((event, session) => {
    if (event === 'PASSWORD_RECOVERY' && session) {
      showPasswordReset();
    }
  });

  if (recoveryLinkError) {
    cleanRecoveryUrl();
    message.textContent = 'Este link de recuperação expirou ou já foi usado. Solicite um novo link.';
  } else if (isRecoveryLink) {
    supabaseClient.auth.getSession().then(({ data }) => {
      if (data && data.session) showPasswordReset();
    });
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    message.textContent = '';
    button.disabled = true;
    button.textContent = 'Acessando...';
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
      button.textContent = 'Acessar CRM';
    }
  });
});
