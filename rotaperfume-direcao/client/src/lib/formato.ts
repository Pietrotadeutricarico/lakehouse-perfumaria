/**
 * Formatacao em portugues, e a defesa contra a armadilha que atinge a tela
 * inteira.
 *
 * O warehouse devolve numero como STRING no JSON, mesmo quando o tipo gerado
 * diz `number` -- DECIMAL, SUM() e BIGINT grande chegam assim. Sem passar por
 * Number() antes:
 *   - toLocaleString devolve a string intacta: o "R$" some e aparece
 *     551102.87 cru na tela;
 *   - uma soma vira concatenacao: "7" + "12" da "712".
 */
export function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

export const reais = (v: unknown) =>
  num(v).toLocaleString('pt-BR', {
    style: 'currency',
    currency: 'BRL',
    maximumFractionDigits: 0,
  });

/** Ninguem decide ligacao lendo 0.9425319224443632. */
export const pct = (v: unknown, casas = 0) =>
  `${(num(v) * 100).toLocaleString('pt-BR', { maximumFractionDigits: casas })}%`;
