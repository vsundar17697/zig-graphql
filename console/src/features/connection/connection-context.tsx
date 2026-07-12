import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { GraphQLClient } from "@/lib/graphql/client"
import { fetchSchema, type SchemaModel } from "@/lib/graphql/introspection"

const ENDPOINT_STORAGE_KEY = "pg-gql-console.endpoint"
const DEFAULT_ENDPOINT = "http://localhost:8080/graphql"

export type SchemaState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; schema: SchemaModel }

interface ConnectionValue {
  endpoint: string
  setEndpoint: (endpoint: string) => void
  client: GraphQLClient
  schemaState: SchemaState
  /** Re-runs introspection against the current endpoint. */
  refreshSchema: () => void
}

const ConnectionContext = createContext<ConnectionValue | null>(null)

export function ConnectionProvider({ children }: { children: ReactNode }) {
  const [endpoint, setEndpointState] = useState(
    () => localStorage.getItem(ENDPOINT_STORAGE_KEY) ?? DEFAULT_ENDPOINT,
  )
  const [schemaState, setSchemaState] = useState<SchemaState>({ status: "loading" })
  const client = useMemo(() => new GraphQLClient(endpoint), [endpoint])

  const setEndpoint = useCallback((next: string) => {
    localStorage.setItem(ENDPOINT_STORAGE_KEY, next)
    setEndpointState(next)
  }, [])

  // One in-flight introspection at a time; endpoint changes abort the stale one.
  const abortRef = useRef<AbortController | null>(null)
  const refreshSchema = useCallback(() => {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller

    setSchemaState({ status: "loading" })
    fetchSchema(client, controller.signal)
      .then((schema) => setSchemaState({ status: "ready", schema }))
      .catch((err) => {
        if (controller.signal.aborted) return
        setSchemaState({
          status: "error",
          message: err instanceof Error ? err.message : String(err),
        })
      })
  }, [client])

  useEffect(() => {
    refreshSchema()
    return () => abortRef.current?.abort()
  }, [refreshSchema])

  const value = useMemo(
    () => ({ endpoint, setEndpoint, client, schemaState, refreshSchema }),
    [endpoint, setEndpoint, client, schemaState, refreshSchema],
  )

  return <ConnectionContext.Provider value={value}>{children}</ConnectionContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useConnection(): ConnectionValue {
  const ctx = useContext(ConnectionContext)
  if (!ctx) throw new Error("useConnection must be used inside <ConnectionProvider>")
  return ctx
}
