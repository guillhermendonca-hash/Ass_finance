export default function ConfigNecessaria() {
  return (
    <div className="entrada">
      <div className="entrada__marca">Falta conectar o Supabase</div>
      <p className="entrada__frase">
        O app está de pé, mas ainda não sabe com qual banco falar.
      </p>
      <div className="cartao">
        <ol className="lista-checagem">
          <li>
            Crie um projeto em <code>supabase.com</code>.
          </li>
          <li>
            Copie <code>.env.example</code> para <code>.env</code>.
          </li>
          <li>
            Preencha <code>VITE_SUPABASE_URL</code> e{' '}
            <code>VITE_SUPABASE_ANON_KEY</code> com os valores de{' '}
            <em>Project Settings → API</em>.
          </li>
          <li>
            Rode as migrações de <code>supabase/migrations/</code> na ordem, do{' '}
            <code>0001</code> ao <code>0005</code>.
          </li>
          <li>
            Reinicie o <code>npm run dev</code> — o Vite só lê o <code>.env</code> ao subir.
          </li>
        </ol>
      </div>
      <p className="rodape-nota">
        A <code>anon key</code> é pública por natureza: quem protege os dados é o
        RLS, não o segredo da chave.
      </p>
    </div>
  )
}
