import type { ReactNode } from "react"
import { EndpointBar } from "@/features/connection/EndpointBar"

/**
 * Chrome shared by every console page: brand, endpoint/status bar, and a
 * full-height content slot. Navigation lives in App.tsx as tabs so pages
 * stay mounted (and keep their state) while hidden.
 */
export function AppShell({ nav, children }: { nav: ReactNode; children: ReactNode }) {
  return (
    <div className="flex h-screen flex-col bg-background text-foreground">
      <header className="flex items-center justify-between border-b px-4 py-2">
        <div className="flex items-center gap-6">
          <h1 className="text-sm font-semibold tracking-tight">
            pg-gql <span className="font-normal text-muted-foreground">console</span>
          </h1>
          {nav}
        </div>
        <EndpointBar />
      </header>
      <main className="min-h-0 flex-1">{children}</main>
    </div>
  )
}
