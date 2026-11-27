"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

export function AdminLogoutButton() {
  const router = useRouter();
  const [pending, setPending] = useState(false);

  async function logout() {
    setPending(true);
    try {
      const response = await fetch("/api/v1/admin/auth/logout", { method: "POST" });
      if (response.ok) {
        router.replace("/login");
        router.refresh();
      }
    } finally {
      setPending(false);
    }
  }

  return (
    <button className="admin-link-button" type="button" onClick={logout} disabled={pending}>
      {pending ? "در حال خروج…" : "خروج"}
    </button>
  );
}
