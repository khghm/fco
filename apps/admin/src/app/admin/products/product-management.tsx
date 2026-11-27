"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";

interface Product {
  id: string;
  slug: string;
  title: string;
  status: string;
  version: number;
  updated_at: string | null;
  active_variants: number;
  price_from_rial: number | null;
}

interface ProductDetail {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  brand_id: string | null;
  category_id: string | null;
  attributes: Record<string, unknown>;
  status: string;
  version: number;
  updated_at: string | null;
}

interface PriceVersion {
  id: string;
  amount_rial: number;
  compare_at_rial: number | null;
  channel: string;
  effective_from: string;
  effective_to: string | null;
  created_by: string | null;
}

interface Variant {
  id: string;
  sku: string;
  barcode: string | null;
  is_active: boolean;
  prices: PriceVersion[];
}

interface ApiEnvelope<T> {
  data?: T;
  error?: { code?: string; message?: string; request_id?: string };
  meta?: { request_id?: string; total?: number };
}

class ApiRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly requestId: string,
  ) {
    super(message);
  }
}

async function apiData<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, { cache: "no-store", ...init });
  const payload = (await response.json()) as ApiEnvelope<T>;
  const requestId =
    payload.error?.request_id ??
    payload.meta?.request_id ??
    response.headers.get("X-Request-Id") ??
    "";
  if (!response.ok) {
    throw new ApiRequestError(
      payload.error?.message ?? "درخواست انجام نشد.",
      response.status,
      requestId,
    );
  }
  if (payload.data === undefined) {
    throw new ApiRequestError("پاسخ سرویس ساختار معتبری ندارد.", response.status, requestId);
  }
  return payload.data;
}

function parseAttributes(value: FormDataEntryValue | null): Record<string, unknown> | null {
  if (typeof value !== "string") {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(value);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function rial(value: number | null): string {
  return value === null
    ? "ثبت نشده"
    : `${new Intl.NumberFormat("fa-IR").format(value)} ریال`;
}

export function ProductManagement() {
  const router = useRouter();
  const [products, setProducts] = useState<Product[]>([]);
  const [selected, setSelected] = useState<ProductDetail | null>(null);
  const [variants, setVariants] = useState<Variant[]>([]);
  const [selectedVariantId, setSelectedVariantId] = useState("");
  const [loading, setLoading] = useState(true);
  const [pending, setPending] = useState("");
  const [error, setError] = useState<ApiRequestError | Error | null>(null);
  const [notice, setNotice] = useState("");

  const loadProducts = useCallback(async () => {
    try {
      const data = await apiData<Product[]>("/api/v1/admin/products?limit=100");
      setProducts(data);
      setError(null);
    } catch (caught) {
      setError(caught instanceof Error ? caught : new Error("بارگیری محصولات ناموفق بود."));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let active = true;
    void apiData<Product[]>("/api/v1/admin/products?limit=100")
      .then((data) => {
        if (active) {
          setProducts(data);
          setLoading(false);
        }
      })
      .catch((caught: unknown) => {
        if (active) {
          setError(caught instanceof Error ? caught : new Error("بارگیری محصولات ناموفق بود."));
          setLoading(false);
        }
      });
    return () => {
      active = false;
    };
  }, []);

  function reportError(caught: unknown) {
    const errorValue = caught instanceof Error ? caught : new Error("درخواست انجام نشد.");
    setError(errorValue);
    if (errorValue instanceof ApiRequestError && errorValue.status === 401) {
      router.replace("/login");
    }
  }

  async function openProduct(productId: string) {
    setPending("detail");
    setError(null);
    setNotice("");
    try {
      const [product, productVariants] = await Promise.all([
        apiData<ProductDetail>(`/api/v1/admin/products/${productId}`),
        apiData<Variant[]>(`/api/v1/admin/products/${productId}/variants`),
      ]);
      setSelected(product);
      setVariants(productVariants);
      setSelectedVariantId(productVariants[0]?.id ?? "");
    } catch (caught) {
      reportError(caught);
    } finally {
      setPending("");
    }
  }

  async function createProduct(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const attributes = parseAttributes(form.get("attributes"));
    if (!attributes) {
      setError(new Error("مشخصه‌ها باید یک شیء JSON معتبر باشند."));
      return;
    }
    setPending("product-create");
    setError(null);
    setNotice("");
    try {
      const created = await apiData<{ id: string }>("/api/v1/admin/products", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          slug: form.get("slug"),
          title: form.get("title"),
          description: form.get("description") || null,
          brand_id: form.get("brand_id") || null,
          category_id: form.get("category_id") || null,
          attributes,
        }),
      });
      formElement.reset();
      setNotice("محصول ساخته شد.");
      await loadProducts();
      await openProduct(created.id);
    } catch (caught) {
      reportError(caught);
    } finally {
      setPending("");
    }
  }

  async function updateProduct(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selected) {
      return;
    }
    const form = new FormData(event.currentTarget);
    const attributes = parseAttributes(form.get("attributes"));
    if (!attributes) {
      setError(new Error("مشخصه‌ها باید یک شیء JSON معتبر باشند."));
      return;
    }
    setPending("product-update");
    setError(null);
    setNotice("");
    try {
      await apiData<{ id: string; version: number }>(
        `/api/v1/admin/products/${selected.id}`,
        {
          method: "PATCH",
          headers: {
            "Content-Type": "application/json",
            "If-Match": `"${selected.version}"`,
          },
          body: JSON.stringify({
            title: form.get("title"),
            description: form.get("description") || null,
            brand_id: form.get("brand_id") || null,
            category_id: form.get("category_id") || null,
            attributes,
          }),
        },
      );
      setNotice("تغییرات محصول ذخیره شد.");
      await loadProducts();
      await openProduct(selected.id);
    } catch (caught) {
      reportError(caught);
    } finally {
      setPending("");
    }
  }

  async function createVariant(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selected) {
      return;
    }
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    setPending("variant-create");
    setError(null);
    setNotice("");
    try {
      await apiData<{ id: string }>(`/api/v1/admin/products/${selected.id}/variants`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sku: form.get("sku"),
          barcode: form.get("barcode") || null,
          weight_g: form.get("weight_g") ? Number(form.get("weight_g")) : null,
        }),
      });
      formElement.reset();
      setNotice("تنوع محصول ساخته شد.");
      await openProduct(selected.id);
      await loadProducts();
    } catch (caught) {
      reportError(caught);
    } finally {
      setPending("");
    }
  }

  async function setPrice(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const variant = variants.find((item) => item.id === selectedVariantId);
    if (!variant) {
      setError(new Error("ابتدا یک تنوع محصول انتخاب کنید."));
      return;
    }
    const form = new FormData(event.currentTarget);
    const effectiveLocal = String(form.get("effective_from") ?? "");
    const effectiveFrom = effectiveLocal
      ? new Date(effectiveLocal)
      : new Date();
    if (!Number.isFinite(effectiveFrom.getTime())) {
      setError(new Error("تاریخ اعتبار قیمت معتبر نیست."));
      return;
    }
    setPending("price-create");
    setError(null);
    setNotice("");
    try {
      await apiData<{ id: string }>(
        `/api/v1/admin/variants/${variant.id}/prices`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            amount_rial: Number(form.get("amount_rial")),
            compare_at_rial: form.get("compare_at_rial")
              ? Number(form.get("compare_at_rial"))
              : null,
            effective_from: effectiveFrom.toISOString(),
            channel: form.get("channel") || "web",
            reason: form.get("reason") || null,
          }),
        },
      );
      setNotice("نسخهٔ جدید قیمت ثبت شد؛ نسخه‌های قبلی نگه‌داری شده‌اند.");
      await openProduct(selected?.id ?? "");
    } catch (caught) {
      reportError(caught);
    } finally {
      setPending("");
    }
  }

  return (
    <div className="admin-management">
      {error && (
        <div className="admin-alert admin-alert-error" role="alert">
          <strong>{error.message}</strong>
          {error instanceof ApiRequestError && (
            <p>
              وضعیت {error.status}
              {error.requestId ? ` · شناسهٔ درخواست: ${error.requestId}` : ""}
              {error.status === 403 ? " · نقش فعلی اجازهٔ این عملیات را ندارد." : ""}
              {error.status === 409 ? " · داده تغییر کرده؛ دوباره بارگیری و تلاش کنید." : ""}
            </p>
          )}
        </div>
      )}
      {notice && <p className="admin-alert admin-alert-success" role="status">{notice}</p>}

      <div className="admin-panel">
        <h2>محصول تازه</h2>
        <form className="admin-form-grid" onSubmit={createProduct}>
          <label>
            شناسهٔ یکتا (slug)
            <input name="slug" required maxLength={120} pattern="[a-z0-9]+(-[a-z0-9]+)*" />
          </label>
          <label>
            عنوان
            <input name="title" required maxLength={240} />
          </label>
          <label className="admin-field-wide">
            توضیحات
            <textarea name="description" rows={3} maxLength={5000} />
          </label>
          <label>
            شناسهٔ برند (اختیاری)
            <input name="brand_id" />
          </label>
          <label>
            شناسهٔ دسته‌بندی (اختیاری)
            <input name="category_id" />
          </label>
          <label className="admin-field-wide">
            مشخصه‌ها (JSON)
            <textarea name="attributes" rows={3} defaultValue="{}" required />
          </label>
          <button type="submit" disabled={pending !== ""}>
            {pending === "product-create" ? "در حال ساخت…" : "ساخت محصول"}
          </button>
        </form>
      </div>

      <div className="admin-panel">
        <div className="admin-panel-heading">
          <h2>محصولات</h2>
          <button type="button" className="admin-secondary-button" onClick={() => void loadProducts()}>
            تازه‌سازی
          </button>
        </div>
        {loading ? (
          <p role="status">در حال بارگیری محصولات…</p>
        ) : products.length === 0 ? (
          <p className="admin-muted">محصولی برای نمایش وجود ندارد.</p>
        ) : (
          <div className="admin-table-wrap">
            <table className="admin-table">
              <thead>
                <tr>
                  <th>محصول</th>
                  <th>وضعیت</th>
                  <th>تنوع فعال</th>
                  <th>کمترین قیمت فعال</th>
                  <th>نسخه</th>
                  <th>جزئیات</th>
                </tr>
              </thead>
              <tbody>
                {products.map((product) => (
                  <tr key={product.id}>
                    <td>
                      <strong>{product.title}</strong>
                      <small>{product.slug}</small>
                    </td>
                    <td>{product.status}</td>
                    <td>{new Intl.NumberFormat("fa-IR").format(product.active_variants)}</td>
                    <td>{rial(product.price_from_rial)}</td>
                    <td>{product.version}</td>
                    <td>
                      <button
                        type="button"
                        className="admin-secondary-button"
                        onClick={() => void openProduct(product.id)}
                        disabled={pending !== ""}
                      >
                        ویرایش و قیمت
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {selected && (
        <div className="admin-panel">
          <div className="admin-panel-heading">
            <div>
              <h2>{selected.title}</h2>
              <p className="admin-muted">
                {selected.slug} · نسخه {selected.version} · {selected.status}
              </p>
            </div>
            <button type="button" className="admin-secondary-button" onClick={() => setSelected(null)}>
              بستن
            </button>
          </div>
          <form
            className="admin-form-grid"
            key={`${selected.id}-${selected.version}`}
            onSubmit={updateProduct}
          >
            <label>
              عنوان
              <input name="title" required maxLength={240} defaultValue={selected.title} />
            </label>
            <label>
              شناسهٔ برند
              <input name="brand_id" defaultValue={selected.brand_id ?? ""} />
            </label>
            <label>
              شناسهٔ دسته‌بندی
              <input name="category_id" defaultValue={selected.category_id ?? ""} />
            </label>
            <label className="admin-field-wide">
              توضیحات
              <textarea name="description" rows={3} maxLength={5000} defaultValue={selected.description ?? ""} />
            </label>
            <label className="admin-field-wide">
              مشخصه‌ها (JSON)
              <textarea
                name="attributes"
                rows={4}
                defaultValue={JSON.stringify(selected.attributes, null, 2)}
                required
              />
            </label>
            <button type="submit" disabled={pending !== ""}>
              {pending === "product-update" ? "در حال ذخیره…" : "ذخیرهٔ محصول"}
            </button>
          </form>

          <hr className="admin-divider" />
          <h3>تنوع‌ها و تاریخچهٔ قیمت</h3>
          {variants.length === 0 ? (
            <p className="admin-muted">هنوز تنوعی برای این محصول ثبت نشده است.</p>
          ) : (
            <div className="admin-variant-list">
              {variants.map((variant) => (
                <article className="admin-variant-card" key={variant.id}>
                  <div className="admin-panel-heading">
                    <div>
                      <strong>{variant.sku}</strong>
                      <small>{variant.barcode ?? "بدون بارکد"}</small>
                    </div>
                    <span>{variant.is_active ? "فعال" : "غیرفعال"}</span>
                  </div>
                  {variant.prices.length === 0 ? (
                    <p className="admin-muted">قیمتی ثبت نشده است.</p>
                  ) : (
                    <ol className="admin-price-history">
                      {variant.prices.map((price) => (
                        <li key={price.id}>
                          <span>{rial(price.amount_rial)}</span>
                          <small>
                            {price.channel} · شروع {new Date(price.effective_from).toLocaleString("fa-IR")}
                            {price.effective_to
                              ? ` · پایان ${new Date(price.effective_to).toLocaleString("fa-IR")}`
                              : " · نسخهٔ جاری"}
                          </small>
                        </li>
                      ))}
                    </ol>
                  )}
                </article>
              ))}
            </div>
          )}

          <div className="admin-form-columns">
            <form className="admin-form-grid" onSubmit={createVariant}>
              <h3 className="admin-field-wide">افزودن تنوع</h3>
              <label>
                SKU
                <input name="sku" required maxLength={32} pattern="[A-Za-z0-9._-]+" />
              </label>
              <label>
                بارکد (اختیاری)
                <input name="barcode" maxLength={32} />
              </label>
              <label>
                وزن به گرم (اختیاری)
                <input name="weight_g" type="number" min={1} step={1} />
              </label>
              <button type="submit" disabled={pending !== ""}>
                {pending === "variant-create" ? "در حال ساخت…" : "ساخت تنوع"}
              </button>
            </form>

            <form className="admin-form-grid" onSubmit={setPrice}>
              <h3 className="admin-field-wide">ثبت قیمت نسخه‌دار</h3>
              <label>
                تنوع
                <select
                  value={selectedVariantId}
                  onChange={(event) => setSelectedVariantId(event.currentTarget.value)}
                  required
                >
                  <option value="" disabled>انتخاب کنید</option>
                  {variants.map((variant) => (
                    <option key={variant.id} value={variant.id}>{variant.sku}</option>
                  ))}
                </select>
              </label>
              <label>
                مبلغ (ریال)
                <input name="amount_rial" type="number" min={0} step={1} required />
              </label>
              <label>
                قیمت قبل از تخفیف (اختیاری)
                <input name="compare_at_rial" type="number" min={0} step={1} />
              </label>
              <label>
                شروع اعتبار (اختیاری)
                <input name="effective_from" type="datetime-local" />
              </label>
              <label>
                کانال
                <input name="channel" defaultValue="web" required maxLength={40} />
              </label>
              <label className="admin-field-wide">
                دلیل تغییر (اختیاری)
                <input name="reason" maxLength={500} />
              </label>
              <button type="submit" disabled={pending !== "" || variants.length === 0}>
                {pending === "price-create" ? "در حال ثبت…" : "ثبت نسخهٔ قیمت"}
              </button>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
