import { ESFERAS, SELO } from '../lib/esferas'

export function Selo({ visibilidade }) {
  const { classe, texto } = SELO[visibilidade] ?? SELO.privado
  return <span className={`selo ${classe}`}>{texto}</span>
}

/**
 * O texto de cada opção existe para o usuário decidir sem precisar lembrar
 * da regra — principalmente a do meio, que é a que se erra.
 */
export default function SeletorVisibilidade({ valor, aoMudar }) {
  return (
    <div className="campo">
      <span className="campo__rotulo">Quem vê</span>
      <div className="opcoes">
        {ESFERAS.map((esfera) => (
          <button
            key={esfera.valor}
            type="button"
            aria-pressed={valor === esfera.valor}
            onClick={() => aoMudar(esfera.valor)}
          >
            <span className="opcoes__titulo">{esfera.titulo}</span>
            <span className="opcoes__nota">{esfera.nota}</span>
          </button>
        ))}
      </div>
    </div>
  )
}
