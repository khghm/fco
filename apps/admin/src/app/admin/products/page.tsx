import { ProductManagement } from "./product-management";

export default function AdminProductsPage() {
  return (
    <section className="admin-page">
      <p className="admin-eyebrow">کاتالوگ</p>
      <h1>مدیریت محصول و قیمت</h1>
      <p className="admin-muted">
        تغییرات محصول با کنترل نسخه انجام می‌شود و هر قیمت، نسخهٔ تازه و غیرقابل‌ویرایش است.
      </p>
      <ProductManagement />
    </section>
  );
}
