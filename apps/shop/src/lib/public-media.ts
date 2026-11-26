import type {
  PublicProductDetail,
  PublicProductMedia,
} from "@fco/application/catalog";
import { createPresignedMediaUrl } from "@fco/infrastructure/media";

export type PublicProductMediaWithUrl = PublicProductMedia & { url: string };
export type PublicProductWithMediaUrls = Omit<PublicProductDetail, "media"> & {
  media: PublicProductMediaWithUrl[];
};

export async function addPublicMediaUrls(
  product: PublicProductDetail,
): Promise<PublicProductWithMediaUrls> {
  return {
    ...product,
    media: await Promise.all(
      product.media.map(async (media) => ({
        ...media,
        url: await createPresignedMediaUrl(media.key),
      })),
    ),
  };
}
