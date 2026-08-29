import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  AlertTitle,
  BarChart,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyTitle,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { num } from '../../lib/formato';

export function AcompanhamentoPage() {
  const { data, loading, error } = useAnalyticsQuery('acompanhamento', {});

  const linhas = data ?? [];
  const naFila = linhas.reduce((s, l) => s + num(l.na_fila), 0);
  const trabalhados = linhas.reduce((s, l) => s + num(l.trabalhados), 0);
  const vendeu = linhas.reduce((s, l) => s + num(l.vendeu), 0);

  // So' quem ja tem retorno entra no grafico -- 35 barras zeradas nao contam
  // historia nenhuma.
  const comMovimento = linhas.filter((l) => num(l.trabalhados) > 0);

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <div>
        <h2 className="text-2xl font-bold text-foreground">Acompanhamento</h2>
        <p className="text-sm text-muted-foreground mt-1">
          {loading
            ? 'Carregando...'
            : trabalhados === 0
              ? 'Nenhuma ligação registrada até agora.'
              : `${trabalhados} dos ${naFila} contatos foram trabalhados, e ${vendeu} viraram pedido.`}
        </p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertTitle>Não foi possível carregar o acompanhamento</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {loading && (
        <div className="space-y-2">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-12 w-full" />
          ))}
        </div>
      )}

      {!loading && !error && trabalhados === 0 && (
        <Empty>
          <EmptyTitle>Ainda não há retorno registrado</EmptyTitle>
          <EmptyDescription>
            Este número aparece assim que o time marcar o resultado das ligações na aba{' '}
            <strong>A semana</strong>. E ele não serve só para acompanhar: o que o vendedor
            responde aqui vira o dado de treino do modelo da semana que vem — inclusive sobre
            quem não comprou porque ninguém ligou. Zero não é erro, é o começo.
          </EmptyDescription>
        </Empty>
      )}

      {!loading && !error && trabalhados > 0 && (
        <>
          {comMovimento.length > 0 && (
            <Card className="shadow-sm">
              <CardHeader>
                <CardTitle>Trabalhados e convertidos, por vendedor</CardTitle>
              </CardHeader>
              <CardContent>
                <BarChart
                  data={comMovimento.map((l) => ({
                    vendedor: String(l.vendedor),
                    trabalhados: num(l.trabalhados),
                    vendeu: num(l.vendeu),
                  }))}
                  xKey="vendedor"
                  yKey={['trabalhados', 'vendeu']}
                  showLegend
                  height={280}
                  ariaLabel="Contatos trabalhados e convertidos por vendedor"
                />
              </CardContent>
            </Card>
          )}

          <Card className="shadow-sm">
            <CardHeader>
              <CardTitle>Desfecho por vendedor</CardTitle>
            </CardHeader>
            <CardContent className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Vendedor</TableHead>
                    <TableHead className="text-right">Na fila</TableHead>
                    <TableHead className="text-right">Trabalhados</TableHead>
                    <TableHead className="text-right">Vendeu</TableHead>
                    <TableHead className="text-right">Vai pensar</TableHead>
                    <TableHead className="text-right">Sem interesse</TableHead>
                    <TableHead className="text-right">Não atendeu</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {linhas.map((l) => (
                    <TableRow key={String(l.vendedor)}>
                      <TableCell className="font-medium">{l.vendedor}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {num(l.na_fila)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {num(l.trabalhados)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{num(l.vendeu)}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {num(l.vai_pensar)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {num(l.sem_interesse)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {num(l.nao_atendeu)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
