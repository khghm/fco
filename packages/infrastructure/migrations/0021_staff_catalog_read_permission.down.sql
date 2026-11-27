grant execute on function iam.unlock_if_expired(uuid) to public;

delete from iam.role_permissions rp
using iam.permissions p
where rp.permission_id = p.id
  and p.key = 'catalog.product.read';

delete from iam.permissions
where key = 'catalog.product.read';
