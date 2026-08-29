import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  AlertTitle,
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { sql } from '@databricks/appkit-ui/js';
import { useState } from 'react';
import { num, reais, pct } from '../../lib/formato';

const TODOS = 'Todos';

const STATUS_ROTULO: Record<string, string> = {
  vendeu: 'Vendeu',
  vai_pensar: 'Vai pensar',
  sem_interesse: 'Sem interesse',
  nao_atendeu: 'Não atendeu',
};

const BOTOES = [
  { status: 'vendeu', rotulo: 'Vendeu' },
  { status: 'vai_pensar', rotulo: 'Vai pensar' },
  { status: 'sem_interesse', rotulo: 'Sem interesse' },
  { status: 'nao_atendeu', rotulo: 'Não atendeu' },
] as const;

function Kpi({
  titulo,
  valor,
  apoio,
  carregando,
}: {
  titulo: string;
  valor: string;
  apoio: string;
  carregando: boolean;
}) {
  return (
    <Card className="shadow-sm">
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">{titulo}</CardTitle>
      </CardHeader>
      <CardContent>
        {carregando ? (
          <div className="space-y-2">
            <Skeleton className="h-8 w-28" />
            <Skeleton className="h-3 w-36" />
          </div>
        ) : (
          <>
            <div className="text-3xl font-bold tabular-nums text-foreground">{valor}</div>
            <p className="text-xs text-muted-foreground mt-1">{apoio}</p>
          </>
        )}
      </CardContent>
    </Card>
  );
}

/**
 * O conteudo que le do warehouse. Ele e' REMONTADO pelo pai a cada gravacao,
 * atraves de uma `key` que muda -- e' assim que a consulta e' refeita.
 *
 * useAnalyticsQuery nao tem refetch. A alternativa comum e' inventar um
 * parametro que nao filtra nada (:recarga >= 0) so' para furar o cache, mas
 * isso quebra a tela de quem estiver com a pagina aberta de uma versao
 * anterior: o navegador manda a consulta sem o parametro novo e o warehouse
 * recusa com UNBOUND_SQL_PARAMETER. Remontar nao inventa coluna nem parametro.
 */
function Conteudo({
  vendedor,
  onVendedorChange,
  comentarios,
  onComentarioChange,
  onGravado,
}: {
  vendedor: string;
  onVendedorChange: (v: string) => void;
  comentarios: Record<number, string>;
  onComentarioChange: (clienteId: number, texto: string) => void;
  onGravado: () => void;
}) {
  const kpis = useAnalyticsQuery('kpis_semana', {});
  const vendedores = useAnalyticsQuery('vendedores', {});
  const fila = useAnalyticsQuery('fila', { vendedor: sql.string(vendedor) });

  const [gravando, setGravando] = useState<number | null>(null);
  const [erroGravacao, setErroGravacao] = useState<string | null>(null);

  const k = kpis.data?.[0];
  const referencia = k?.referencia ? String(k.referencia) : '';
  const conversaoPrevista = k ? num(k.acertos_top200) / Math.max(num(k.contatos), 1) : 0;
  const erroLeitura = kpis.error ?? vendedores.error ?? fila.error;

  async function registrar(clienteId: number, vendedorLinha: string, status: string) {
    setGravando(clienteId);
    setErroGravacao(null);
    try {
      const resp = await fetch('/api/retorno', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          cliente_id: clienteId,
          vendedor: vendedorLinha,
          status,
          comentario: comentarios[clienteId] ?? '',
          referencia,
        }),
      });
      if (!resp.ok) {
        const corpo = await resp.json().catch(() => ({}));
        throw new Error(corpo?.erro ?? `Falha ao gravar (HTTP ${resp.status})`);
      }
      onGravado();
    } catch (e) {
      setErroGravacao(e instanceof Error ? e.message : String(e));
    } finally {
      setGravando(null);
    }
  }

  return (
    <>
      <div>
        <h2 className="text-2xl font-bold text-foreground">A semana</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Os {num(k?.contatos)} clientes com maior chance de comprar nos próximos 7 dias
          {referencia ? ` · fila de ${referencia}` : ''}
          {k?.versao ? ` · modelo versão ${num(k.versao)}` : ''}
        </p>
      </div>

      {erroLeitura && (
        <Alert variant="destructive">
          <AlertTitle>Não foi possível carregar a fila</AlertTitle>
          <AlertDescription>{erroLeitura}</AlertDescription>
        </Alert>
      )}

      {erroGravacao && (
        <Alert variant="destructive">
          <AlertTitle>O retorno não foi gravado</AlertTitle>
          <AlertDescription>
            {erroGravacao}. Nada foi registrado — tente de novo.
          </AlertDescription>
        </Alert>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Kpi
          titulo="Contatos da semana"
          valor={num(k?.contatos).toLocaleString('pt-BR')}
          apoio={`${num(k?.vendedores)} vendedores`}
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Receita esperada"
          valor={reais(k?.receita_esperada)}
          apoio="soma de score × ticket médio"
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Conversão prevista"
          valor={pct(conversaoPrevista, 1)}
          apoio={`contra ${pct(k?.taxa_base, 1)} ligando às cegas`}
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Já trabalhados"
          valor={num(k?.trabalhados).toLocaleString('pt-BR')}
          apoio={
            `${num(k?.viraram_pedido)} viraram pedido`
          }
          carregando={kpis.loading}
        />
      </div>

      <Card className="shadow-sm">
        <CardHeader className="flex flex-row items-center justify-between gap-4 flex-wrap">
          <CardTitle>Quem ligar primeiro</CardTitle>
          <Select value={vendedor} onValueChange={onVendedorChange}>
            <SelectTrigger className="w-[280px]">
              <SelectValue placeholder="Filtrar por vendedor" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={TODOS}>Todos os vendedores</SelectItem>
              {(vendedores.data ?? []).map((v) => (
                <SelectItem key={v.vendedor} value={v.vendedor}>
                  {v.vendedor} ({num(v.contatos)})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </CardHeader>

        <CardContent>
          {fila.loading && (
            <div className="space-y-2">
              {Array.from({ length: 6 }).map((_, i) => (
                <Skeleton key={i} className="h-12 w-full" />
              ))}
            </div>
          )}

          {!fila.loading && fila.data && fila.data.length === 0 && (
            <Empty>
              <EmptyTitle>Nenhum contato para {vendedor} nesta semana</EmptyTitle>
              <EmptyDescription>
                A fila é global: os 200 contatos são os de maior chance da base inteira, não
                uma cota por vendedor. Quem está com a carteira mais fria recebe menos — e
                isso está correto, porque cota igual obrigaria alguém a deixar cliente quente
                na mesa.
              </EmptyDescription>
            </Empty>
          )}

          {!fila.loading && fila.data && fila.data.length > 0 && (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-12">#</TableHead>
                    <TableHead>Cliente</TableHead>
                    <TableHead>Vendedor</TableHead>
                    <TableHead className="text-right">Chance</TableHead>
                    <TableHead>Por que ligar</TableHead>
                    <TableHead>O que oferecer</TableHead>
                    <TableHead className="min-w-[260px]">Como foi a ligação</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {fila.data.map((linha) => {
                    const id = num(linha.cliente_id);
                    const jaTemRetorno = Boolean(linha.retorno_status);
                    return (
                      <TableRow key={id}>
                        <TableCell className="tabular-nums text-muted-foreground">
                          {num(linha.ordem)}
                        </TableCell>
                        <TableCell>
                          <div className="font-medium">{linha.razao_social}</div>
                          <div className="text-xs text-muted-foreground">
                            {linha.cidade}/{linha.uf} · ticket {reais(linha.ticket_medio)}
                          </div>
                        </TableCell>
                        <TableCell className="text-sm">{linha.vendedor}</TableCell>
                        <TableCell className="text-right">
                          <Badge variant={num(linha.score) >= 0.5 ? 'default' : 'secondary'}>
                            {pct(linha.score)}
                          </Badge>
                        </TableCell>
                        <TableCell className="text-sm max-w-[15rem]">{linha.motivo}</TableCell>
                        <TableCell className="text-sm max-w-[15rem] text-muted-foreground">
                          {linha.sugestao}
                        </TableCell>

                        <TableCell>
                          {jaTemRetorno ? (
                            <div className="space-y-1">
                              <Badge
                                variant={
                                  linha.retorno_status === 'vendeu' ? 'default' : 'secondary'
                                }
                              >
                                {STATUS_ROTULO[String(linha.retorno_status)] ??
                                  String(linha.retorno_status)}
                              </Badge>
                              {linha.retorno_comentario && (
                                <p className="text-xs text-muted-foreground">
                                  {linha.retorno_comentario}
                                </p>
                              )}
                            </div>
                          ) : (
                            <div className="space-y-2">
                              <Input
                                placeholder="o que o cliente disse"
                                value={comentarios[id] ?? ''}
                                onChange={(e) => onComentarioChange(id, e.target.value)}
                                disabled={gravando === id}
                                className="h-8 text-xs"
                              />
                              <div className="grid grid-cols-2 gap-1">
                                {BOTOES.map((b) => (
                                  <Button
                                    key={b.status}
                                    size="sm"
                                    className="w-full"
                                    variant={b.status === 'vendeu' ? 'default' : 'outline'}
                                    disabled={gravando !== null}
                                    onClick={() =>
                                      registrar(id, String(linha.vendedor), b.status)
                                    }
                                  >
                                    {gravando === id ? '...' : b.rotulo}
                                  </Button>
                                ))}
                              </div>
                            </div>
                          )}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </>
  );
}

export function SemanaPage() {
  // Filtro e comentarios moram no PAI: o filho e' remontado a cada gravacao,
  // e o que estiver dentro dele se perderia.
  const [vendedor, setVendedor] = useState<string>(TODOS);
  const [comentarios, setComentarios] = useState<Record<number, string>>({});
  const [versao, setVersao] = useState(0);

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <Conteudo
        key={versao}
        vendedor={vendedor}
        onVendedorChange={setVendedor}
        comentarios={comentarios}
        onComentarioChange={(id, texto) =>
          setComentarios((c) => ({ ...c, [id]: texto }))
        }
        onGravado={() => setVersao((v) => v + 1)}
      />
    </div>
  );
}
