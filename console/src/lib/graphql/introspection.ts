import { GraphQLClient } from "./client"

/**
 * Introspection layer: one query, unwrapped into a small model the UI
 * navigates directly. This is deliberately *not* the full GraphQL type
 * system — it is exactly what the explorer, query runner and data browser
 * need, so features depend on a stable local shape instead of raw
 * introspection JSON.
 */

const INTROSPECTION_QUERY = /* GraphQL */ `
  query ConsoleIntrospection {
    __schema {
      queryType {
        name
      }
      mutationType {
        name
      }
      types {
        name
        kind
        description
        fields {
          name
          description
          args {
            name
            type {
              ...TypeRef
            }
          }
          type {
            ...TypeRef
          }
        }
        inputFields {
          name
          type {
            ...TypeRef
          }
        }
        enumValues {
          name
        }
      }
    }
  }

  fragment TypeRef on __Type {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
`

interface RawTypeRef {
  kind: string
  name: string | null
  ofType?: RawTypeRef | null
}

interface RawField {
  name: string
  description: string | null
  args?: { name: string; type: RawTypeRef }[]
  type: RawTypeRef
}

interface RawType {
  name: string
  kind: string
  description: string | null
  fields: RawField[] | null
  inputFields: { name: string; type: RawTypeRef }[] | null
  enumValues: { name: string }[] | null
}

interface RawIntrospection {
  __schema: {
    queryType: { name: string } | null
    mutationType: { name: string } | null
    types: RawType[]
  }
}

/** A type reference with the modifier chain flattened. */
export interface TypeRef {
  /** The named type at the bottom of the NON_NULL/LIST chain. */
  baseType: string
  /** Kind of the named type (OBJECT, SCALAR, INPUT_OBJECT, ENUM, ...). */
  baseKind: string
  /** Rendered GraphQL syntax, e.g. "[album!]!". */
  display: string
  isList: boolean
}

export interface FieldInfo {
  name: string
  description: string | null
  type: TypeRef
  args: { name: string; type: TypeRef }[]
}

export interface TypeInfo {
  name: string
  kind: string
  description: string | null
  fields: FieldInfo[]
  inputFields: { name: string; type: TypeRef }[]
  enumValues: string[]
}

export interface SchemaModel {
  /** Root Query fields — for pg-gql: one per collection, plus _aggregate and _by_pk variants. */
  queryFields: FieldInfo[]
  /** Root Mutation fields — insert_/update_/delete_ procedures. */
  mutationFields: FieldInfo[]
  /** Every named type, introspection builtins (__*) excluded. */
  types: Map<string, TypeInfo>
}

function flattenTypeRef(ref: RawTypeRef): TypeRef {
  let display = ""
  let isList = false

  const render = (r: RawTypeRef): string => {
    if (r.kind === "NON_NULL" && r.ofType) return `${render(r.ofType)}!`
    if (r.kind === "LIST" && r.ofType) {
      isList = true
      return `[${render(r.ofType)}]`
    }
    return r.name ?? "?"
  }
  display = render(ref)

  let base: RawTypeRef = ref
  while (base.ofType) base = base.ofType

  return {
    baseType: base.name ?? "?",
    baseKind: base.kind,
    display,
    isList,
  }
}

function toFieldInfo(raw: RawField): FieldInfo {
  return {
    name: raw.name,
    description: raw.description,
    type: flattenTypeRef(raw.type),
    args: (raw.args ?? []).map((a) => ({ name: a.name, type: flattenTypeRef(a.type) })),
  }
}

export async function fetchSchema(client: GraphQLClient, signal?: AbortSignal): Promise<SchemaModel> {
  const { response } = await client.execute<RawIntrospection>({
    query: INTROSPECTION_QUERY,
    signal,
  })

  if (response.errors?.length || !response.data) {
    const detail = response.errors?.[0]?.message ?? "no data in response"
    throw new Error(`schema introspection failed: ${detail}`)
  }

  const schema = response.data.__schema
  const types = new Map<string, TypeInfo>()

  for (const t of schema.types) {
    if (t.name.startsWith("__")) continue
    types.set(t.name, {
      name: t.name,
      kind: t.kind,
      description: t.description,
      fields: (t.fields ?? []).map(toFieldInfo),
      inputFields: (t.inputFields ?? []).map((f) => ({
        name: f.name,
        type: flattenTypeRef(f.type),
      })),
      enumValues: (t.enumValues ?? []).map((v) => v.name),
    })
  }

  const rootFields = (rootName: string | null): FieldInfo[] =>
    rootName ? (types.get(rootName)?.fields ?? []) : []

  return {
    queryFields: rootFields(schema.queryType?.name ?? null),
    mutationFields: rootFields(schema.mutationType?.name ?? null),
    types,
  }
}
