(function (root) {
  const message = 'Sua conta foi acessada em outro aparelho. Entre novamente para continuar.';

  function create(client, onReplaced) {
    let timer = null;
    let generation = 0;
    let pending = null;
    let disconnected = false;

    function stop() {
      generation += 1;
      if (timer !== null) root.clearInterval(timer);
      timer = null;
      root.removeEventListener('focus', poll);
      root.document.removeEventListener('visibilitychange', visible);
    }

    async function validate() {
      if (pending) return pending;
      const current = generation;
      const request = (async () => {
        const { data, error } = await client.rpc('get_app_session_status');
        if (error) throw error;
        if (current !== generation) return false;
        if (!data || typeof data.active !== 'boolean') throw new Error('Nao foi possivel validar sua sessao. Tente novamente.');
        if (!data.active) {
          stop();
          if (!disconnected) {
            disconnected = true;
            try {
              const { error: signOutError } = await client.auth.signOut({ scope: 'local' });
              if (signOutError) console.warn('Falha ao encerrar sessao local:', signOutError);
            } finally {
              onReplaced(message);
            }
          }
          const replaced = new Error(message);
          replaced.code = 'APP_SESSION_REPLACED';
          throw replaced;
        }
        return true;
      })();
      pending = request;
      try { return await request; } finally { if (pending === request) pending = null; }
    }

    async function poll() {
      try { await validate(); } catch (error) {
        if (error.code !== 'APP_SESSION_REPLACED') console.warn('Falha ao verificar sessao:', error);
      }
    }

    function visible() {
      if (root.document.visibilityState === 'visible') poll();
    }

    function start() {
      if (timer !== null) return;
      timer = root.setInterval(poll, 15000);
      root.addEventListener('focus', poll);
      root.document.addEventListener('visibilitychange', visible);
    }

    async function claimAfterSignIn() {
      stop();
      // An earlier poll must never disconnect the newly authenticated session.
      if (pending) await pending.catch(() => {});
      disconnected = false;
      try {
        const { error } = await client.rpc('claim_app_session');
        if (error) throw error;
        // Status is authoritative, including foundation's enforcement=false phase.
        if (!await validate()) throw new Error('Nao foi possivel validar sua sessao. Tente novamente.');
      } catch (error) {
        stop();
        if (!disconnected) {
          disconnected = true;
          try {
            const { error: signOutError } = await client.auth.signOut({ scope: 'local' });
            if (signOutError) console.warn('Falha ao encerrar sessao local:', signOutError);
          } catch (signOutError) {
            console.warn('Falha ao encerrar sessao local:', signOutError);
          }
        }
        if (String(error.message || '').includes('SESSAO_SUBSTITUIDA')) {
          const replaced = new Error(message);
          replaced.code = 'APP_SESSION_REPLACED';
          throw replaced;
        }
        throw error;
      }
    }

    async function logout() {
      stop();
      try {
        const { error } = await client.rpc('release_app_session');
        if (error) console.warn('Falha ao liberar sessao:', error);
      } catch (error) {
        console.warn('Falha ao liberar sessao:', error);
      } finally {
        const { error } = await client.auth.signOut({ scope: 'local' });
        if (error) throw error;
      }
    }

    return { claimAfterSignIn, validate, start, stop, logout };
  }

  root.AppSessionGuard = { create, message };
})(window);
