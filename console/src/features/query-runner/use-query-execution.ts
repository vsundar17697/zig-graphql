import { useCallback, useRef, useState } from "react"
import { useConnection } from "@/features/connection/connection-context"
import { TransportError, type ExecuteResult } from "@/lib/graphql/types"

export type ExecutionState =
  | { status: "idle" }
  | { status: "running" }
  | { status: "done"; result: ExecuteResult }
  | { status: "transport-error"; message: string }

/**
 * Owns one document execution at a time: running a new one aborts the old,
 * transport failures and GraphQL-envelope errors surface as distinct states
 * (envelope errors are still a "done" — the server answered).
 */
export function useQueryExecution() {
  const { client } = useConnection()
  const [state, setState] = useState<ExecutionState>({ status: "idle" })
  const abortRef = useRef<AbortController | null>(null)

  const run = useCallback(
    async (query: string, variablesJson: string) => {
      let variables: Record<string, unknown> | undefined
      const trimmed = variablesJson.trim()
      if (trimmed.length > 0) {
        try {
          variables = JSON.parse(trimmed)
        } catch (err) {
          setState({
            status: "transport-error",
            message: `variables pane is not valid JSON: ${err instanceof Error ? err.message : String(err)}`,
          })
          return
        }
        if (typeof variables !== "object" || variables === null || Array.isArray(variables)) {
          setState({ status: "transport-error", message: "variables must be a JSON object" })
          return
        }
      }

      abortRef.current?.abort()
      const controller = new AbortController()
      abortRef.current = controller

      setState({ status: "running" })
      try {
        const result = await client.execute({ query, variables, signal: controller.signal })
        if (!controller.signal.aborted) setState({ status: "done", result })
      } catch (err) {
        if (controller.signal.aborted) return
        if (err instanceof DOMException && err.name === "AbortError") return
        setState({
          status: "transport-error",
          message: err instanceof TransportError ? err.message : String(err),
        })
      }
    },
    [client],
  )

  return { state, run }
}
