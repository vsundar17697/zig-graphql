import { useCallback, useState } from "react"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Textarea } from "@/components/ui/textarea"
import { SchemaExplorer } from "@/features/schema-explorer/SchemaExplorer"
import { useQueryExecution } from "./use-query-execution"

const DEFAULT_DOCUMENT = `# Pick a root field from the explorer, or write a document here.
# Cmd/Ctrl+Enter runs it.
{
  __typename
}
`

/**
 * GraphiQL-style page: schema explorer | document + variables | results.
 * The editor is a plain textarea on purpose for now — the layering means a
 * CodeMirror upgrade later touches exactly one component.
 */
export function QueryRunnerPage() {
  const [document, setDocument] = useState(DEFAULT_DOCUMENT)
  const [variables, setVariables] = useState("")
  const { state, run } = useQueryExecution()

  const runNow = useCallback(() => run(document, variables), [run, document, variables])

  const onEditorKeyDown = (e: React.KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault()
      runNow()
    }
  }

  return (
    <div className="grid h-full grid-cols-[260px_minmax(0,1fr)_minmax(0,1fr)]">
      <aside className="min-h-0 border-r">
        <SchemaExplorer onInsert={setDocument} />
      </aside>

      <section className="flex min-h-0 flex-col border-r">
        <div className="flex items-center justify-between border-b px-3 py-1.5">
          <span className="text-xs font-medium text-muted-foreground">Document</span>
          <Button size="sm" onClick={runNow} disabled={state.status === "running"}>
            {state.status === "running" ? "Running…" : "Run ▶"}
          </Button>
        </div>
        <Textarea
          value={document}
          onChange={(e) => setDocument(e.target.value)}
          onKeyDown={onEditorKeyDown}
          spellCheck={false}
          aria-label="GraphQL document"
          className="min-h-0 flex-[3] resize-none rounded-none border-0 font-mono text-xs focus-visible:ring-0"
        />
        <div className="border-t">
          <div className="px-3 py-1.5">
            <span className="text-xs font-medium text-muted-foreground">
              Variables <span className="font-normal">(JSON)</span>
            </span>
          </div>
          <Textarea
            value={variables}
            onChange={(e) => setVariables(e.target.value)}
            onKeyDown={onEditorKeyDown}
            spellCheck={false}
            placeholder="{ }"
            aria-label="Query variables as JSON"
            className="h-28 resize-none rounded-none border-0 font-mono text-xs focus-visible:ring-0"
          />
        </div>
      </section>

      <section className="flex min-h-0 flex-col">
        <div className="flex h-[41px] items-center gap-2 border-b px-3">
          <span className="text-xs font-medium text-muted-foreground">Result</span>
          {state.status === "done" && (
            <>
              <Badge variant="outline" className="text-[10px]">
                {state.result.durationMs.toFixed(0)} ms
              </Badge>
              {state.result.response.errors?.length ? (
                <Badge variant="destructive" className="text-[10px]">
                  {state.result.response.errors.length} error(s)
                </Badge>
              ) : null}
            </>
          )}
        </div>
        <ScrollArea className="min-h-0 flex-1">
          <ResultBody state={state} />
        </ScrollArea>
      </section>
    </div>
  )
}

function ResultBody({ state }: { state: ReturnType<typeof useQueryExecution>["state"] }) {
  switch (state.status) {
    case "idle":
      return <p className="p-3 text-xs text-muted-foreground">Run a document to see its result.</p>
    case "running":
      return <p className="p-3 text-xs text-muted-foreground">Running…</p>
    case "transport-error":
      return (
        <Alert variant="destructive" className="m-3 w-auto">
          <AlertTitle>Request failed</AlertTitle>
          <AlertDescription className="break-all font-mono text-xs">
            {state.message}
          </AlertDescription>
        </Alert>
      )
    case "done":
      return (
        <pre className="p-3 font-mono text-xs leading-relaxed">
          {JSON.stringify(state.result.response, null, 2)}
        </pre>
      )
  }
}
