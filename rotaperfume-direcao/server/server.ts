import { createApp, analytics, genie, server, getExecutionContext } from '@databricks/appkit';
import { z } from 'zod';

/**
 * O CONTRATO do retorno.
 *
 * Os quatro botoes da tela existem para a PESSOA; este enum existe para o
 * DADO. Se o front pudesse mandar status livre, em tres semanas a tabela
 * teria "vendeu", "Vendeu", "vendido" e "VENDEU" -- e nenhuma query de
 * conversao voltaria a fechar.
 *
 * Validacao no servidor, nao no botao: botao e' interface, nao contrato.
 */
const STATUS = ['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu'] as const;

const RetornoSchema = z.object({
  // z.coerce porque a tela manda o id que veio do warehouse, e ele chega
  // como STRING mesmo estando tipado como number.
  cliente_id: z.coerce.number().int().positive(),
  vendedor: z.string().trim().min(1, 'informe o vendedor'),
  status: z.enum(STATUS),
  comentario: z.string().trim().max(500).optional(),
  referencia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'use o formato aaaa-mm-dd'),
});

await createApp({
  plugins: [
    analytics(),
    genie({ spaces: { direcao: process.env.DATABRICKS_GENIE_SPACE_ID } }),
    server(),
  ],
  // A fila muda inteira quando alguem clica num botao, e sao 200 linhas.
  // Com cache ligado, a tela continuaria mostrando o numero de antes depois
  // de gravar -- ou seja, mentindo.
  cache: { enabled: false },
  async onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      // Quem esta logado. O Databricks Apps injeta o e-mail nos headers.
      app.get('/api/quem-sou', (req, res) => {
        const email =
          (req.headers['x-forwarded-email'] as string | undefined) ??
          (req.headers['x-forwarded-preferred-username'] as string | undefined) ??
          null;
        res.json({
          email,
          usuario: (req.headers['x-forwarded-user'] as string | undefined) ?? null,
          executaComo: email ? 'usuario' : 'service principal do app',
        });
      });

      // A UNICA rota que escreve. Leitura continua sendo arquivo .sql tipado.
      app.post('/api/retorno', async (req, res) => {
        const parsed = RetornoSchema.safeParse(req.body);
        if (!parsed.success) {
          // 400 ANTES de tocar no warehouse: corpo invalido nao vira consulta.
          res.status(400).json({
            erro: 'Retorno invalido',
            aceitos: STATUS,
            detalhe: parsed.error.issues.map((i) => ({
              campo: i.path.join('.'),
              problema: i.message,
            })),
          });
          return;
        }

        const r = parsed.data;
        const registradoPor =
          (req.headers['x-forwarded-email'] as string | undefined) ?? 'desenvolvimento-local';

        try {
          const ctx = getExecutionContext();
          // warehouseId e' uma Promise no contexto -- sem o await, o INSERT
          // sai com "[object Promise]" no lugar do id.
          const warehouseId = await ctx.warehouseId;
          if (!warehouseId) {
            res.status(500).json({ erro: 'Warehouse nao disponivel no contexto' });
            return;
          }

          // Todo valor vai em `parameters`. Nada e' concatenado na string do
          // SQL: comentario e' texto livre digitado por um vendedor.
          await ctx.client.statementExecution.executeStatement({
            warehouse_id: warehouseId,
            wait_timeout: '30s',
            statement: `
              INSERT INTO lakehouse_rotaperfume.gold.retorno_ligacao
                (cliente_id, vendedor, status, comentario,
                 registrado_em, registrado_por, _referencia)
              VALUES
                (:cliente_id, :vendedor, :status, :comentario,
                 current_timestamp(), :registrado_por, :referencia)
            `,
            parameters: [
              { name: 'cliente_id', value: String(r.cliente_id), type: 'INT' },
              { name: 'vendedor', value: r.vendedor, type: 'STRING' },
              { name: 'status', value: r.status, type: 'STRING' },
              // value ausente grava NULL. A API tipa value como string|undefined,
              // entao `null` nao compila -- e `undefined` e' o jeito certo de
              // dizer "sem comentario".
              { name: 'comentario', value: r.comentario || undefined, type: 'STRING' },
              { name: 'registrado_por', value: registradoPor, type: 'STRING' },
              { name: 'referencia', value: r.referencia, type: 'DATE' },
            ],
          });

          res.status(201).json({ ok: true, registrado_por: registradoPor });
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          console.error('[retorno] falha ao gravar:', msg);
          res.status(500).json({ erro: 'Nao consegui gravar o retorno', detalhe: msg });
        }
      });
    });
  },
}).catch(console.error);
