# helpers

## first-install.sh

Setup completo de uma máquina Ubuntu (24.04) nova para desenvolvimento web.

Rode como seu usuário (não use `sudo`) — o script pede a senha quando precisar:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/matheusbozetti/helpers/main/first-install.sh)
```

> `wget` já vem no Ubuntu; o `curl` não. Se já tiver curl:
> `bash <(curl -fsSL https://raw.githubusercontent.com/matheusbozetti/helpers/main/first-install.sh)`

- Etapas já instaladas são puladas. Para reinstalar tudo: `FORCE=1 bash <(wget -qO- ...)`.
- Ao final, faça logout/login.
