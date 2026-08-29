import {
  Alert,
  AlertDescription,
  AlertTitle,
  Badge,
  GenieChat,
  Skeleton,
} from '@databricks/appkit-ui/react';
import { useEffect, useState } from 'react';

type QuemSou = {
  email: string | null;
  usuario: string | null;
  executaComo: string;
};

/**
 * A aba de perguntar. Uma resposta de IA so' e' confiavel se der para ver
 * COMO ela foi produzida e EM NOME DE QUEM ela rodou -- por isso a tela
 * carrega quem esta logado e avisa, de forma permanente, que a resposta e'
 * gerada e traz o SQL que a produziu.
 */
export function PerguntarPage() {
  const [quem, setQuem] = useState<QuemSou | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);

  useEffect(() => {
    let ativo = true;
    fetch('/api/quem-sou')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d: QuemSou) => ativo && setQuem(d))
      .catch((e: Error) => ativo && setErro(e.message))
      .finally(() => ativo && setCarregando(false));
    return () => {
      ativo = false;
    };
  }, []);

  return (
    <div className="space-y-4 w-full max-w-4xl mx-auto">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h2 className="text-2xl font-bold text-foreground">Perguntar</h2>
          <p className="text-sm text-muted-foreground mt-1">
            O mesmo Genie da direção, aqui dentro. Pergunte com as suas palavras — por
            exemplo, <em>quanto vale a fila desta semana?</em>
          </p>
        </div>

        {/* Identidade: quem pergunta, e em nome de quem a consulta roda. */}
        {carregando ? (
          <Skeleton className="h-6 w-56" />
        ) : quem?.email ? (
          <Badge variant="secondary" className="whitespace-nowrap">
            {quem.email}
          </Badge>
        ) : null}
      </div>

      {erro && (
        <Alert variant="destructive">
          <AlertTitle>Não consegui identificar quem está logado</AlertTitle>
          <AlertDescription>
            {erro}. As perguntas continuam funcionando, mas sem confirmar a identidade de
            quem as executa.
          </AlertDescription>
        </Alert>
      )}

      {/* Aviso permanente, nao um toast que some. */}
      <Alert>
        <AlertTitle>As respostas são geradas por IA — confira antes de decidir</AlertTitle>
        <AlertDescription>
          Cada resposta traz o SQL que a produziu: abra e leia antes de levar o número para
          uma reunião. A consulta roda{' '}
          {quem?.email ? (
            <>
              em nome de <strong>{quem.email}</strong>, respeitando as permissões dessa
              pessoa no Unity Catalog
            </>
          ) : (
            <>com a identidade do próprio aplicativo</>
          )}
          . Este espaço responde sobre a fila, o retorno das ligações e o desempenho do
          modelo; ele não conhece dado fora dessas tabelas.
        </AlertDescription>
      </Alert>

      <div className="h-[min(600px,65vh)] border rounded-lg overflow-hidden">
        <GenieChat alias="direcao" />
      </div>
    </div>
  );
}
