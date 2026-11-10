-- New items always wait in Admin -> Item approvals, even when the store owner
-- is also a super admin. Before this, items_guard returned early for admins,
-- the app doesn't send approval_status, and the column default was 'approved',
-- so an admin's own uploads went live without showing in the queue.
alter table public.items alter column approval_status set default 'pending';

create or replace function public.items_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    NEW.approval_status := 'pending'; NEW.approval_note := null; NEW.submitted_at := now();
    NEW.featured_until := null; NEW.featured_source := null;
    return NEW;
  end if;
  if public.is_admin() then return NEW; end if;   -- admins approve / reject / feature through updates
  NEW.approval_status := OLD.approval_status; NEW.approval_note := OLD.approval_note; NEW.submitted_at := OLD.submitted_at;
  NEW.featured_until := OLD.featured_until; NEW.featured_source := OLD.featured_source;
  if OLD.approval_status = 'rejected' and row(NEW.name, NEW.price, NEW.description, NEW.category, NEW.category_other_name, NEW.image_url, NEW.stock, NEW.listing_type)
       is distinct from row(OLD.name, OLD.price, OLD.description, OLD.category, OLD.category_other_name, OLD.image_url, OLD.stock, OLD.listing_type) then
    NEW.approval_status := 'pending'; NEW.approval_note := null; NEW.submitted_at := now();
  end if;
  return NEW;
end; $$;
