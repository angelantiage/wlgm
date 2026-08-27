# WLGM · Work Less, Grow More

El software que sostiene el círculo completo: reserva, confirma, recuerda y da
seguimiento. La sesión y la venta NO se delegan — eso lo hace la directora.

## Qué hay aquí

| Carpeta | Qué es |
|---|---|
| `app/index.html` | la app entera: un archivo, sin dependencias, sin build |
| `sql/` | las migraciones de la base (Supabase) |

## Para verla en la Mac

    python3 -m http.server 8777 --directory ~/wlgm/app

y abrir http://localhost:8777

## Cómo está protegida

- RLS prendido en todas las tablas. Cada directora ve SOLO lo suyo.
- Verificado con la llave pública: un extraño recibe 0 filas de todo.
- La llave que va en el HTML es la publishable: es pública a propósito.
  Lo que protege los datos es el RLS, no la llave.
