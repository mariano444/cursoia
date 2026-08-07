# Conexión AcademIA + Supabase + GalioPay

## 1. Aplicar la base de datos

1. Entrá a Supabase → SQL Editor.
2. Pegá y ejecutá todo el archivo `supabase_schema_curso_ia.sql`.

Esto crea:

- perfiles de alumnos;
- curso, módulos y lecciones con `page_key`;
- inscripciones;
- progreso por clase;
- certificados bloqueados hasta 100%;
- órdenes de pago GalioPay;
- función `activate_enrollment_from_payment(...)` para activar el acceso desde el webhook.

## 2. Configurar secretos de las Edge Functions

En Supabase, cargá estos secretos en el proyecto `iomaxlhnkvllpdneexxz`:

```bash
npx supabase secrets set GALIOPAY_CLIENT_ID="TU_CLIENT_ID" --project-ref iomaxlhnkvllpdneexxz
npx supabase secrets set GALIOPAY_API_KEY="TU_API_KEY_PRIVADA" --project-ref iomaxlhnkvllpdneexxz
npx supabase secrets set SITE_URL="https://tu-dominio.com" --project-ref iomaxlhnkvllpdneexxz
npx supabase secrets set COURSE_PRICE_ARS="4990" --project-ref iomaxlhnkvllpdneexxz
npx supabase secrets set GALIOPAY_SANDBOX="false" --project-ref iomaxlhnkvllpdneexxz
```

Si activás firma HMAC en GalioPay:

```bash
npx supabase secrets set GALIOPAY_WEBHOOK_SECRET="TU_WEBHOOK_SECRET" --project-ref iomaxlhnkvllpdneexxz
```

## 3. Desplegar funciones

```bash
npx supabase functions deploy crear-pago-galiopay --project-ref iomaxlhnkvllpdneexxz
npx supabase functions deploy galiopay-webhook --project-ref iomaxlhnkvllpdneexxz
```

La función `crear-pago-galiopay` requiere sesión de Supabase (`verify_jwt = true`).
La función `galiopay-webhook` queda pública para GalioPay (`verify_jwt = false`) y valida HMAC si configurás `GALIOPAY_WEBHOOK_SECRET`.

## 4. Configurar Auth

Para que el alumno pueda pagar y entrar inmediatamente, en Supabase Auth conviene desactivar la confirmación obligatoria de email o usar una política de confirmación rápida. Si la confirmación de email está activa, el frontend le pedirá al alumno confirmar el correo antes de crear el pago.

## 5. Flujo final

1. Alumno completa nombre, email, contraseña y WhatsApp.
2. La landing crea/inicia sesión en Supabase.
3. La Edge Function crea una orden `payment_orders`.
4. GalioPay devuelve el link de pago.
5. El alumno paga en GalioPay.
6. GalioPay llama a `galiopay-webhook`.
7. Supabase marca la orden como `approved` y crea la inscripción.
8. El alumno cursa, marca clases como completas y ve su avance.
9. Al llegar al 100%, Supabase emite el certificado.
10. La landing desbloquea el certificado con el nombre completo del alumno.
