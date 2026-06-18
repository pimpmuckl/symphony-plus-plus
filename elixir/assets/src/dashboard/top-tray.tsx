import type * as React from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export function TopTray({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Card className="dashboard-glass-surface top-tray-card overflow-hidden">
      <CardHeader className="pb-3">
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}
