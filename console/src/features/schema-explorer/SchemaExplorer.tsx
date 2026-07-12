import { useState } from "react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Separator } from "@/components/ui/separator"
import { Skeleton } from "@/components/ui/skeleton"
import { useConnection } from "@/features/connection/connection-context"
import type { FieldInfo, SchemaModel, TypeInfo } from "@/lib/graphql/introspection"

/**
 * Introspection-driven schema sidebar: root Query/Mutation fields, and a
 * drill-down into any named type. Clicking a root field hands a starter
 * document to the editor via `onInsert`, so the explorer composes with any
 * host page rather than owning editor state itself.
 */
export function SchemaExplorer({ onInsert }: { onInsert?: (document: string) => void }) {
  const { schemaState } = useConnection()
  const [openType, setOpenType] = useState<string | null>(null)

  if (schemaState.status === "loading") {
    return (
      <div className="space-y-2 p-3">
        {Array.from({ length: 8 }, (_, i) => (
          <Skeleton key={i} className="h-5 w-full" />
        ))}
      </div>
    )
  }

  if (schemaState.status === "error") {
    return (
      <div className="p-3 text-xs text-destructive" role="alert">
        {schemaState.message}
      </div>
    )
  }

  const { schema } = schemaState
  const selected = openType ? schema.types.get(openType) : null

  return (
    <ScrollArea className="h-full">
      <div className="p-3">
        {selected ? (
          <TypeDetail
            type={selected}
            onBack={() => setOpenType(null)}
            onOpenType={(name) => schema.types.has(name) && setOpenType(name)}
          />
        ) : (
          <RootList schema={schema} onOpenType={setOpenType} onInsert={onInsert} />
        )}
      </div>
    </ScrollArea>
  )
}

function RootList({
  schema,
  onOpenType,
  onInsert,
}: {
  schema: SchemaModel
  onOpenType: (name: string) => void
  onInsert?: (document: string) => void
}) {
  return (
    <div className="space-y-4">
      <FieldGroup
        heading="Queries"
        fields={schema.queryFields}
        onOpenType={onOpenType}
        onInsert={onInsert && ((f) => onInsert(starterQuery(f, schema)))}
      />
      <Separator />
      <FieldGroup
        heading="Mutations"
        fields={schema.mutationFields}
        onOpenType={onOpenType}
        onInsert={onInsert && ((f) => onInsert(starterMutation(f)))}
      />
    </div>
  )
}

function FieldGroup({
  heading,
  fields,
  onOpenType,
  onInsert,
}: {
  heading: string
  fields: FieldInfo[]
  onOpenType: (name: string) => void
  onInsert?: (field: FieldInfo) => void
}) {
  return (
    <section>
      <h3 className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
        {heading}
      </h3>
      {fields.length === 0 && <p className="text-xs text-muted-foreground">none exposed</p>}
      <ul className="space-y-0.5">
        {fields.map((f) => (
          <li key={f.name} className="group flex items-baseline gap-1.5 text-xs">
            <button
              type="button"
              className="truncate font-mono text-foreground hover:underline"
              title={onInsert ? `Insert a starter document for ${f.name}` : f.name}
              onClick={() => onInsert?.(f)}
            >
              {f.name}
            </button>
            <button
              type="button"
              className="shrink-0 font-mono text-muted-foreground hover:text-foreground hover:underline"
              title={`Open type ${f.type.baseType}`}
              onClick={() => onOpenType(f.type.baseType)}
            >
              {f.type.display}
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

function TypeDetail({
  type,
  onBack,
  onOpenType,
}: {
  type: TypeInfo
  onBack: () => void
  onOpenType: (name: string) => void
}) {
  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <Button variant="ghost" size="sm" onClick={onBack} className="h-6 px-2 text-xs">
          ← back
        </Button>
        <span className="font-mono text-sm font-semibold">{type.name}</span>
        <Badge variant="secondary" className="text-[10px]">
          {type.kind.toLowerCase().replace("_", " ")}
        </Badge>
      </div>
      {type.description && <p className="text-xs text-muted-foreground">{type.description}</p>}

      {type.fields.length > 0 && (
        <MemberList label="fields" members={type.fields} onOpenType={onOpenType} />
      )}
      {type.inputFields.length > 0 && (
        <MemberList label="input fields" members={type.inputFields} onOpenType={onOpenType} />
      )}
      {type.enumValues.length > 0 && (
        <section>
          <h4 className="mb-1 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
            values
          </h4>
          <ul className="space-y-0.5 font-mono text-xs">
            {type.enumValues.map((v) => (
              <li key={v}>{v}</li>
            ))}
          </ul>
        </section>
      )}
    </div>
  )
}

function MemberList({
  label,
  members,
  onOpenType,
}: {
  label: string
  members: { name: string; type: { display: string; baseType: string } }[]
  onOpenType: (name: string) => void
}) {
  return (
    <section>
      <h4 className="mb-1 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
        {label}
      </h4>
      <ul className="space-y-0.5">
        {members.map((m) => (
          <li key={m.name} className="flex items-baseline gap-1.5 font-mono text-xs">
            <span>{m.name}:</span>
            <button
              type="button"
              className="text-muted-foreground hover:text-foreground hover:underline"
              onClick={() => onOpenType(m.type.baseType)}
            >
              {m.type.display}
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

/** A runnable starter for a root query field: scalar fields of the result
 * type, so the inserted document executes as-is. */
function starterQuery(field: FieldInfo, schema: SchemaModel): string {
  const resultType = schema.types.get(field.type.baseType)
  const scalarish = (resultType?.fields ?? [])
    .filter((f) => f.type.baseKind === "SCALAR" || f.type.baseKind === "ENUM")
    .slice(0, 6)
  const body = scalarish.length > 0 ? scalarish.map((f) => `    ${f.name}`).join("\n") : "    __typename"
  return `{\n  ${field.name} {\n${body}\n  }\n}`
}

/** Mutations need arguments the console can't guess; insert a shape with the
 * argument list spelled out for the user to fill in. */
function starterMutation(field: FieldInfo): string {
  const args = field.args.map((a) => `${a.name}: ___`).join(", ")
  const argSuffix = args.length > 0 ? `(${args})` : ""
  return `mutation {\n  ${field.name}${argSuffix} {\n    __typename\n  }\n}`
}
