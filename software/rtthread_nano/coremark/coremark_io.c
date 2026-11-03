#include <stdarg.h>
#include <stdint.h>

#include <rtthread.h>

static void append_character(char *buffer, unsigned int capacity,
                             unsigned int *length, char value)
{
    if (*length + 1u < capacity)
    {
        buffer[*length] = value;
    }
    (*length)++;
}

static void append_string(char *buffer, unsigned int capacity,
                          unsigned int *length, const char *value)
{
    if (value == 0)
    {
        value = "(NULL)";
    }
    while (*value != '\0')
    {
        append_character(buffer, capacity, length, *value++);
    }
}

static void append_unsigned(char *buffer, unsigned int capacity,
                            unsigned int *length, uint32_t value,
                            unsigned int base, unsigned int width,
                            char padding)
{
    static const char digits[] = "0123456789abcdef";
    char reverse[16];
    unsigned int count = 0u;

    do
    {
        reverse[count++] = digits[value % base];
        value /= base;
    } while (value != 0u);

    while (count < width)
    {
        append_character(buffer, capacity, length, padding);
        width--;
    }
    while (count != 0u)
    {
        append_character(buffer, capacity, length, reverse[--count]);
    }
}

static void append_fixed6(char *buffer, unsigned int capacity,
                          unsigned int *length, double value)
{
    uint32_t whole;
    uint32_t fraction;

    if (value < 0.0)
    {
        append_character(buffer, capacity, length, '-');
        value = -value;
    }

    whole = (uint32_t)value;
    fraction = (uint32_t)(((value - (double)whole) * 1000000.0) + 0.5);
    if (fraction >= 1000000u)
    {
        whole++;
        fraction -= 1000000u;
    }

    append_unsigned(buffer, capacity, length, whole, 10u, 0u, ' ');
    append_character(buffer, capacity, length, '.');
    append_unsigned(buffer, capacity, length, fraction, 10u, 6u, '0');
}

void coremark_printf(const char *format, ...)
{
    char buffer[256];
    va_list arguments;
    unsigned int length = 0u;

    va_start(arguments, format);
    while (*format != '\0')
    {
        unsigned int width = 0u;
        char padding = ' ';
        int long_argument = 0;

        if (*format != '%')
        {
            append_character(buffer, sizeof(buffer), &length, *format++);
            continue;
        }

        format++;
        if (*format == '%')
        {
            append_character(buffer, sizeof(buffer), &length, *format++);
            continue;
        }
        if (*format == '0')
        {
            padding = '0';
            format++;
        }
        while ((*format >= '0') && (*format <= '9'))
        {
            width = width * 10u + (unsigned int)(*format++ - '0');
        }
        if (*format == 'l')
        {
            long_argument = 1;
            format++;
        }

        switch (*format)
        {
            case 's':
                append_string(buffer, sizeof(buffer), &length,
                              va_arg(arguments, const char *));
                break;
            case 'c':
                append_character(buffer, sizeof(buffer), &length,
                                 (char)va_arg(arguments, int));
                break;
            case 'd':
            case 'i':
            {
                long signed_value = long_argument ?
                    va_arg(arguments, long) : (long)va_arg(arguments, int);
                uint32_t magnitude;

                if (signed_value < 0)
                {
                    append_character(buffer, sizeof(buffer), &length, '-');
                    magnitude = (uint32_t)(-(signed_value + 1L)) + 1u;
                }
                else
                {
                    magnitude = (uint32_t)signed_value;
                }
                append_unsigned(buffer, sizeof(buffer), &length, magnitude,
                                10u, width, padding);
                break;
            }
            case 'u':
            {
                uint32_t value = long_argument ?
                    (uint32_t)va_arg(arguments, unsigned long) :
                    va_arg(arguments, uint32_t);
                append_unsigned(buffer, sizeof(buffer), &length, value,
                                10u, width, padding);
                break;
            }
            case 'x':
            case 'X':
            {
                uint32_t value = long_argument ?
                    (uint32_t)va_arg(arguments, unsigned long) :
                    va_arg(arguments, uint32_t);
                append_unsigned(buffer, sizeof(buffer), &length, value,
                                16u, width, padding);
                break;
            }
            case 'f':
                append_fixed6(buffer, sizeof(buffer), &length,
                              va_arg(arguments, double));
                break;
            default:
                append_character(buffer, sizeof(buffer), &length, '%');
                append_character(buffer, sizeof(buffer), &length, *format);
                break;
        }
        if (*format != '\0')
        {
            format++;
        }
    }
    va_end(arguments);

    if (length >= sizeof(buffer))
    {
        length = sizeof(buffer) - 1u;
    }
    buffer[length] = '\0';
    rt_kprintf("%s", buffer);
}
