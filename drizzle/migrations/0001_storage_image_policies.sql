
CREATE POLICY "image managers read" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id IN ('property-images','product-images')
         AND public.can_manage_property_folder(auth.uid(), (storage.foldername(name))[1]));
CREATE POLICY "image managers insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id IN ('property-images','product-images')
         AND lower(storage.extension(name)) IN ('jpg','jpeg','png','webp')
         AND public.can_manage_property_folder(auth.uid(), (storage.foldername(name))[1]));
CREATE POLICY "image managers update" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id IN ('property-images','product-images')
         AND public.can_manage_property_folder(auth.uid(), (storage.foldername(name))[1]))
  WITH CHECK (bucket_id IN ('property-images','product-images')
         AND lower(storage.extension(name)) IN ('jpg','jpeg','png','webp')
         AND public.can_manage_property_folder(auth.uid(), (storage.foldername(name))[1]));
CREATE POLICY "image managers delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id IN ('property-images','product-images')
         AND public.can_manage_property_folder(auth.uid(), (storage.foldername(name))[1]));
