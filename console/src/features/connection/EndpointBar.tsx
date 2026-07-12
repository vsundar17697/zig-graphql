import { useState } from "react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useConnection } from "./connection-context"

/**
 * Endpoint control + live connection status. The status dot is driven by the
 * schema fetch: if introspection succeeds the server is reachable and
 * speaking GraphQL, which is the only readiness the console cares about.
 */
export function EndpointBar() {
  const { endpoint, setEndpoint, schemaState, refreshSchema } = useConnection()
  const [draft, setDraft] = useState(endpoint)
  const dirty = draft !== endpoint

  const status =
    schemaState.status === "ready"
      ? { label: "connected", className: "bg-emerald-500" }
      : schemaState.status === "loading"
        ? { label: "connecting", className: "bg-amber-500 animate-pulse" }
        : { label: "unreachable", className: "bg-red-500" }

  return (
    <div className="flex items-center gap-2">
      <span className="relative flex size-2.5" title={status.label}>
        <span className={`absolute inline-flex size-full rounded-full ${status.className}`} />
      </span>
      <Badge variant="outline" className="font-normal text-muted-foreground">
        {status.label}
      </Badge>
      <form
        className="flex items-center gap-2"
        onSubmit={(e) => {
          e.preventDefault()
          if (dirty) setEndpoint(draft)
          else refreshSchema()
        }}
      >
        <Input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          spellCheck={false}
          className="w-80 font-mono text-xs"
          aria-label="GraphQL endpoint"
        />
        <Button type="submit" variant="secondary" size="sm">
          {dirty ? "Connect" : "Reload schema"}
        </Button>
      </form>
    </div>
  )
}
