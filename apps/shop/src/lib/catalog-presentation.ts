const persianNumber = new Intl.NumberFormat("fa-IR");

export function formatPrice(rial: number | null): string {
  if (rial === null) {
    return "قیمت ثبت نشده";
  }

  const amount = BigInt(rial);
  if (amount % 10n !== 0n) {
    return `${persianNumber.format(amount)} ریال`;
  }

  return `${persianNumber.format(amount / 10n)} تومان`;
}

export { persianNumber };
