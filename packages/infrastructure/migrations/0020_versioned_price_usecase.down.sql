revoke execute on function
  pricing.price_set(uuid, uuid, bigint, bigint, timestamptz, text, text, text)
from fco_app;
drop function pricing.price_set(uuid, uuid, bigint, bigint, timestamptz, text, text, text);

delete from iam.role_permissions rp
using iam.permissions p
where rp.permission_id = p.id
  and p.key = 'pricing.price.update';

delete from iam.permissions
where key = 'pricing.price.update';
