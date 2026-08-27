-- WLGM · El motor de cadencia.
-- Una anotación deja SIEMPRE tres rastros:
--   1. la interacción con su color  (la cajita de la ficha de papel de Angel)
--   2. el color actual del contacto
--   3. la próxima fecha, según SU cadencia
-- Corre como quien la llama: si el contacto no es tuyo, el RLS la para.

create or replace function wlgm_dias_al_siguiente(n int)
returns int language sql immutable as $$
  -- Mediana de 217 casos de su propia bitácora, limpiada. 6 intentos en 61 días.
  select case n when 0 then 2 when 1 then 2 when 2 then 4
                when 3 then 8 when 4 then 15 else 30 end
$$;

create or replace function wlgm_anotar(
  p_contacto   uuid,
  p_resultado  text,
  p_nota       text        default null,
  p_cita       timestamptz default null,
  p_modalidad  text        default 'presencial'
) returns jsonb
language plpgsql
as $$
declare
  c            contactos%rowtype;
  v_yo         uuid := wlgm_yo();
  v_color      text;
  v_canal      text := 'whatsapp';
  v_dir        text := 'saliente';
  v_avisos     text[] := '{}';
  v_cita_id    uuid;
  v_intentos   int;
  v_tz         text;
  TOPE         constant int := 6;
begin
  select * into c from contactos where id = p_contacto;
  if not found then raise exception 'No encuentro a esa persona (o no es tuya).'; end if;
  if v_yo is null then raise exception 'No hay sesión de consultora.'; end if;
  select coalesce(zona_horaria,'America/Denver') into v_tz from consultoras where id = v_yo;

  v_color := case p_resultado
    when 'no_contesto' then 'amarillo' when 'contesto'  then 'azul'
    when 'lo_piensa'   then 'azul'     when 'agendo'    then 'rosa'
    when 'atendida'    then 'morado'   when 'compro'    then 'turquesa'
    when 'no_compro'   then 'cafe'     when 'negocio'   then 'verde'
    when 'registro'    then 'dorado'   when 'baja'      then 'naranja'
    when 'fuera'       then 'gris'     else null end;

  if p_resultado = 'mandado' then
    update contactos set proxima_fecha = current_date + wlgm_dias_al_siguiente(coalesce(intentos,0))
      where id = c.id;

  elsif p_resultado = 'no_contesto' then
    v_canal := 'llamada';
    v_intentos := coalesce(c.intentos,0) + 1;
    if v_intentos >= TOPE then
      update contactos set intentos = v_intentos, etapa = 'descanso',
             proxima_accion = null, proxima_fecha = null where id = c.id;
      v_color := 'gris';
      v_avisos := array_append(v_avisos, format('Llegó a %s intentos, entra en DESCANSO. No se le escribe más hasta que tú lo decidas.', TOPE));
    else
      update contactos set intentos = v_intentos, etapa = 'no_contesta',
             proxima_accion = 'llamar',
             proxima_fecha = current_date + wlgm_dias_al_siguiente(v_intentos) where id = c.id;
    end if;

  elsif p_resultado = 'contesto' then
    v_dir := 'entrante';
    update contactos set etapa = 'conversando', proxima_accion = 'responder',
           intentos = 0, proxima_fecha = current_date,
           consent_whatsapp = true,
           consent_fecha  = coalesce(consent_fecha, now()),
           consent_origen = coalesce(consent_origen, 'contestó el primer mensaje')
      where id = c.id;
    v_avisos := v_avisos || array[
      'CONTESTÓ: primer lugar de la cola y el contador vuelve a cero.',
      'Queda marcado su consentimiento. A partir de aquí el sistema puede seguir solo.'];

  elsif p_resultado = 'lo_piensa' then
    v_dir := 'entrante';
    update contactos set etapa = 'volver_llamar', proxima_accion = 'llamar',
           proxima_fecha = current_date + 4 where id = c.id;   -- su guion: "de 3 a 5 días"

  elsif p_resultado = 'agendo' then
    if p_cita is null then raise exception 'Falta la fecha de la cita.'; end if;
    update contactos set etapa = 'citada', proxima_accion = 'confirmar',
           cita_fecha = p_cita, intentos = 0,
           proxima_fecha = (p_cita at time zone v_tz)::date - 1   -- la víspera
      where id = c.id;
    -- La agendó ELLA, así que el punto de control humano ya ocurrió: nace aceptada.
    insert into citas (contacto_id, consultora_id, para, modalidad, estado, aceptada_en, nota)
      values (c.id, v_yo, p_cita, p_modalidad, 'aceptada', now(), nullif(p_nota,''))
      returning id into v_cita_id;
    v_avisos := array_append(v_avisos, format('Cita el %s. Se confirma el %s, la víspera.',
                    to_char(p_cita at time zone v_tz,'DD/MM'),
                    to_char((p_cita at time zone v_tz)::date - 1,'DD/MM')));

  elsif p_resultado = 'atendida' then
    v_canal := 'presencial';
    update contactos set etapa = 'atendida', proxima_accion = 'seguimiento',
           proxima_fecha = current_date + 2 where id = c.id;
    update citas set estado = 'atendida', atendida_en = now(), actualizado_en = now()
      where contacto_id = c.id and estado in ('propuesta','aceptada','confirmada')
      returning id into v_cita_id;
    -- El 2+2+2 de Angel
    insert into seguimientos (contacto_id, cita_id, tipo, programado) values
      (c.id, v_cita_id, '2dias',    current_date + 2),
      (c.id, v_cita_id, '2semanas', current_date + 14),
      (c.id, v_cita_id, '2meses',   current_date + 60);
    v_avisos := array_append(v_avisos, 'Arranca el 2+2+2: seguimiento a los 2 días, 2 semanas y 2 meses.');
    if exists (select 1 from referidos where referida_id = c.id and cuenta_premio) then
      v_avisos := array_append(v_avisos, 'Vino referida: se le acreditan los $10 a quien la refirió y queda el aviso pendiente.');
    end if;

  elsif p_resultado in ('compro','no_compro') then
    v_canal := 'presencial';
    update contactos set etapa = p_resultado, proxima_accion = 'seguimiento',
           proxima_fecha = current_date + 2 where id = c.id;

  elsif p_resultado = 'negocio' then
    v_dir := 'entrante';
    update contactos set etapa = 'entrevista', proxima_accion = 'seguimiento',
           via = 'negocio', proxima_fecha = current_date where id = c.id;
    v_avisos := array_append(v_avisos, 'Cambia a la VÍA DEL NEGOCIO. Los guiones que le tocan son los de la Misión 5, no los del facial.');

  elsif p_resultado = 'registro' then
    update contactos set etapa = 'registrada', proxima_accion = null,
           proxima_fecha = null, via = 'negocio' where id = c.id;
    v_avisos := array_append(v_avisos, '¡Se registró! Le toca el guion de bienvenida al Área Nacional Poder.');

  elsif p_resultado in ('baja','fuera') then
    update contactos set etapa = case when p_resultado='baja' then 'no_interesada' else 'descanso' end,
           proxima_accion = null, proxima_fecha = null, baja = true,
           baja_motivo = coalesce(nullif(p_nota,''), case when p_resultado='baja'
                          then 'no está interesada' else 'fuera de servicio' end),
           baja_fecha = now() where id = c.id;
    v_avisos := array_append(v_avisos, 'Fuera. No se le vuelve a escribir. Nunca.');

  else
    raise exception 'Resultado que no conozco: %', p_resultado;
  end if;

  -- Rastro 1: la interacción con su color
  insert into interacciones (contacto_id, consultora_id, canal, direccion, color, quien, nota)
    values (c.id, v_yo, v_canal, v_dir, v_color, 'consultora', nullif(p_nota,''));

  -- Rastro 2: el color actual
  if v_color is not null then
    update contactos set color = v_color, ultimo_contacto = current_date,
           llamadas_anotadas = coalesce(llamadas_anotadas,0) + 1,
           actualizado_en = now() where id = c.id;
  end if;

  select * into c from contactos where id = c.id;
  return jsonb_build_object(
    'ok', true, 'nombre', c.nombre, 'color', c.color, 'etapa', c.etapa,
    'intentos', c.intentos, 'proxima_fecha', c.proxima_fecha,
    'proxima_accion', c.proxima_accion, 'avisos', to_jsonb(v_avisos));
end $$;

revoke all on function wlgm_anotar(uuid,text,text,timestamptz,text) from public, anon;
grant  execute on function wlgm_anotar(uuid,text,text,timestamptz,text) to authenticated;
