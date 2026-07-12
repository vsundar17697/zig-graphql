/** Wire types for a spec-shaped GraphQL-over-HTTP response. */

export interface GraphQLError {
  message: string
  path?: (string | number)[]
  locations?: { line: number; column: number }[]
  extensions?: Record<string, unknown>
}

export interface GraphQLResponse<TData = unknown> {
  data?: TData | null
  errors?: GraphQLError[]
}

/** A request that reached the server and came back as a GraphQL envelope —
 * possibly with errors, but structurally sound. */
export interface ExecuteResult<TData = unknown> {
  response: GraphQLResponse<TData>
  /** Round-trip latency in milliseconds, for the status bar. */
  durationMs: number
}

/** Anything that prevented getting a GraphQL envelope back at all:
 * network refused, non-2xx without JSON, malformed body. Distinct from
 * GraphQL execution errors, which arrive inside the envelope. */
export class TransportError extends Error {
  readonly status: number | null

  constructor(message: string, status: number | null = null) {
    super(message)
    this.name = "TransportError"
    this.status = status
  }
}
