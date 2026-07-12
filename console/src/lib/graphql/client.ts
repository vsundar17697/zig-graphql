import { TransportError, type ExecuteResult, type GraphQLResponse } from "./types"

export interface ExecuteOptions {
  /** GraphQL document text. */
  query: string
  /** Document variables, if any. */
  variables?: Record<string, unknown>
  /** For multi-operation documents. */
  operationName?: string
  signal?: AbortSignal
}

/**
 * Minimal GraphQL-over-HTTP client for the pg-gql `/graphql` endpoint.
 * Deliberately dependency-free: the console only ever POSTs a document and
 * reads back one envelope, so a fetch wrapper with honest error separation
 * (TransportError vs errors-in-envelope) beats a client library.
 */
export class GraphQLClient {
  readonly endpoint: string

  constructor(endpoint: string) {
    this.endpoint = endpoint
  }

  async execute<TData = unknown>(options: ExecuteOptions): Promise<ExecuteResult<TData>> {
    const started = performance.now()

    let res: Response
    try {
      res = await fetch(this.endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          query: options.query,
          ...(options.variables !== undefined && { variables: options.variables }),
          ...(options.operationName !== undefined && { operationName: options.operationName }),
        }),
        signal: options.signal ?? null,
      })
    } catch (err) {
      if (err instanceof DOMException && err.name === "AbortError") throw err
      throw new TransportError(
        `cannot reach ${this.endpoint} — is pg-gql-server running? (${err instanceof Error ? err.message : String(err)})`,
      )
    }

    let body: unknown
    try {
      body = await res.json()
    } catch {
      throw new TransportError(
        `${this.endpoint} answered ${res.status} without a JSON body`,
        res.status,
      )
    }

    if (typeof body !== "object" || body === null || !("data" in body || "errors" in body)) {
      throw new TransportError(
        `${this.endpoint} answered ${res.status} with JSON that is not a GraphQL envelope`,
        res.status,
      )
    }

    return {
      response: body as GraphQLResponse<TData>,
      durationMs: performance.now() - started,
    }
  }
}
