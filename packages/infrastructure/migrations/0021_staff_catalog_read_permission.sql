-- =============================================================================
-- 0021_staff_catalog_read_permission — Admin API: catalog read access
-- =============================================================================

insert into iam.permissions (key, domain, description) values
  ('catalog.product.read', 'catalog', 'مشاهدهٔ محصولات مدیریتی')
on conflict (key) do nothing;

insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from (values ('R-SALES', 'catalog.product.read')) as m(role_key, permission_key)
join iam.roles r on r.key = m.role_key
join iam.permissions p on p.key = m.permission_key
on conflict do nothing;

revoke all on function iam.unlock_if_expired(uuid) from public;
grant execute on function iam.unlock_if_expired(uuid) to fco_app;
