import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { AppShell } from "@/components/layout/AppShell"
import { ConnectionProvider } from "@/features/connection/connection-context"

function PagePlaceholder({ title }: { title: string }) {
  return (
    <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
      {title} — coming up next
    </div>
  )
}

export default function App() {
  return (
    <ConnectionProvider>
      <Tabs defaultValue="graphiql" className="h-full gap-0">
        <AppShell
          nav={
            <TabsList>
              <TabsTrigger value="graphiql">GraphiQL</TabsTrigger>
              <TabsTrigger value="data">Data</TabsTrigger>
            </TabsList>
          }
        >
          <TabsContent value="graphiql" className="h-full">
            <PagePlaceholder title="Query runner" />
          </TabsContent>
          <TabsContent value="data" className="h-full">
            <PagePlaceholder title="Data browser" />
          </TabsContent>
        </AppShell>
      </Tabs>
    </ConnectionProvider>
  )
}
