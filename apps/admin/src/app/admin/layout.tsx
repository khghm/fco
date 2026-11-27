import Link from "next/link";
import type { ReactNode } from "react";
import { AdminLogoutButton } from "./logout-button";

export default function AdminLayout({ children }: { children: ReactNode }) {
  return (
    <main className="admin-shell admin-workspace">
      <header className="admin-header">
        <Link href="/" aria-label="صفحهٔ اصلی پنل FCO">FCO</Link>
        <nav aria-label="ناوبری مدیریت">
          <Link href="/admin/products">محصولات و قیمت</Link>
          <Link href="/admin/settings/security">امنیت و MFA</Link>
        </nav>
        <AdminLogoutButton />
      </header>
      {children}
    </main>
  );
}
