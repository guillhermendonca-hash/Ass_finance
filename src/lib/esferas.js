/** As três esferas da seção 3, com o texto que a interface mostra. */
export const ESFERAS = [
  { valor: 'privado', titulo: 'Privado', nota: 'Só você vê. É como tudo nasce.' },
  {
    valor: 'total_compartilhado',
    titulo: 'Compartilhar total',
    nota: 'Ela vê a soma da categoria, nunca este item.',
  },
  { valor: 'casal', titulo: 'Do casal', nota: 'Os dois veem em detalhe e os dois editam.' },
]

export const SELO = {
  privado: { classe: 'selo--privado', texto: 'privado' },
  total_compartilhado: { classe: 'selo--total', texto: 'total' },
  casal: { classe: 'selo--casal', texto: 'casal' },
}
